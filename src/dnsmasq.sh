#!/bin/bash

configure_dhcp() {
    log "Configuring DHCP server..."
    
    local config_file="${DNSMASQ_CONF}"
    
    local dns="${DEFAULTS[DNS]}"
    local subnet_oct="${DEFAULTS[SUBNET]}"

    if [[ "${INTERACTIVE_MODE}" == true ]]; then

        if [[ -z "${ARG[DNS]}" ]]; then
            local dns_choice
            dns_choice=$(select_from_list "DNS server:" 1 \
                "Google (8.8.8.8)" \
                "Cloudflare (1.1.1.1)" \
                "OpenDNS (208.67.222.222)" \
                "Local (192.168.${subnet_oct}.1)" \
                "Custom")
            
            case "${dns_choice}" in
                "Google (8.8.8.8)") dns="8.8.8.8" ;;
                "Cloudflare (1.1.1.1)") dns="1.1.1.1" ;;
                "OpenDNS (208.67.222.222)") dns="208.67.222.222" ;;
                "Local (192.168.${subnet_oct}.1)") dns="192.168.${subnet_oct}.1" ;;
                "Custom") 
                    while true; do
                        read -r -p "DNS IP: " dns
                        if validate_ip "${dns}"; then
                            break
                        else
                            echo "Invalid IP address"
                        fi
                    done
                    ;;
            esac
        fi

        if [[ -z "${ARG[SUBNET]}" ]]; then
            while true; do
                read -r -p "Subnet (third octet) [${DEFAULTS[SUBNET]}]: " user_input
                subnet_oct="${user_input:-${DEFAULTS[SUBNET]}}"
                if [[ "${subnet_oct}" =~ ^[0-9]+$ ]] && ((subnet_oct >= 0 && subnet_oct <= 255)); then
                    break
                else
                    echo "Invalid subnet octet. Please enter 0-255"
                fi
            done
        fi
        
        DEFAULTS[SUBNET]="${subnet_oct}"
        DEFAULTS[DNS]="${dns}"
    fi
    
    if { ! [[ "${subnet_oct}" =~ ^[0-9]+$ ]] || ! ((subnet_oct >= 0 && subnet_oct <= 255)); }; then
        error "Invalid subnet octet: ${subnet_oct} (must be 0-255)"
    fi
    
    if ! validate_ip "${dns}"; then
        error "Invalid DNS IP address: ${dns}"
    fi
    
    SUBNET_OCT="${subnet_oct}"
    
    cat > "${config_file}" << EOF
interface=${INTERFACE}
bind-interfaces
dhcp-range=192.168.${SUBNET_OCT}.10,192.168.${SUBNET_OCT}.250,255.255.255.0,12h
dhcp-option=6,192.168.${SUBNET_OCT}.1
dhcp-option=3,192.168.${SUBNET_OCT}.1
dhcp-leasefile=${TMP_DIR}/dhcp.leases
dhcp-authoritative
no-hosts
log-queries
log-dhcp
server=${dns}
cache-size=1000
neg-ttl=60
domain-needed
bogus-priv
EOF
        
    log "DHCP configured: Range=192.168.${SUBNET_OCT}.10-250, DNS=${dns}"
}

configure_dns_spoof() {
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[DNS_SPOOFING]}" ]]; then
            read -r -p "Enable DNS spoofing? (y/N): " enable_dns_spoofing
            if [[ "${enable_dns_spoofing}" =~ ^[Yy]$ ]]; then  
                DEFAULTS[DNS_SPOOFING]=true
            elif [[ "${enable_dns_spoofing}" =~ ^[Nn]$ ]]; then
                DEFAULTS[DNS_SPOOFING]=false
            fi
        fi
        
        if [[ "${DEFAULTS[DNS_SPOOFING]}" == true && -z "${ARG[SPOOF_TARGET_IP]}" ]]; then
            read -r -p "Default Target IP for spoofing (leave empty for AP IP): " target_ip
            if [[ -n "${target_ip}" ]]; then
                if validate_ip "${target_ip}"; then
                     DEFAULTS[SPOOF_TARGET_IP]="${target_ip}"
                else
                     warn "Invalid IP, will default to AP IP for non-explicit domains."
                fi
            fi
        fi
    fi

    [[ "${DEFAULTS[DNS_SPOOFING]}" == true ]] || return

    log "Configuring DNS spoofing..."
    
    local default_target="${DEFAULTS[SPOOF_TARGET_IP]}"
    # If default target is still empty, use AP IP
    if [[ -z "${default_target}" ]]; then
        default_target="192.168.${SUBNET_OCT}.1"
    fi

    if [[ -n "${ARG[SPOOF_DOMAINS]}" ]]; then
        IFS='|' read -ra entries <<< "$SPOOF_DOMAINS"
        for spoof_entry in "${entries[@]}"; do
            # Check if entry has explicit IP (contains =)
            if [[ "${spoof_entry}" == *"="* ]]; then
                if [[ "${spoof_entry}" =~ ^[^=]+=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo "address=/${spoof_entry/=//}" >> "${DNSMASQ_CONF}"
                    log "Added DNS spoof: ${spoof_entry}"
                else
                    warn "Invalid format for DNS spoofing entry: ${spoof_entry}. Use Format: domain.com=192.168.1.1"
                fi
            else
                # No IP specified, use default target
                 echo "address=/${spoof_entry}/${default_target}" >> "${DNSMASQ_CONF}"
                 log "Added DNS spoof: ${spoof_entry} -> ${default_target}"
            fi
        done
    else
        while read -r -p "Enter domains to spoof (format: domain.com or domain.com=1.2.3.4), empty line to finish: " spoof_entry && [[ -n "${spoof_entry}" ]]; do
            if [[ "${spoof_entry}" == *"="* ]]; then
                if [[ "${spoof_entry}" =~ ^[^=]+=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo "address=/${spoof_entry/=//}" >> "${DNSMASQ_CONF}"
                    log "Added DNS spoof: ${spoof_entry}"
                else
                    echo "Invalid format. Use: domain.com=192.168.1.1"
                fi
            else
                 # domain only
                 echo "address=/${spoof_entry}/${default_target}" >> "${DNSMASQ_CONF}"
                 log "Added DNS spoof: ${spoof_entry} -> ${default_target}"
            fi
        done
    fi

    log "DNS Spoofing Enabled. (configure manually in dnsmasq.conf if needed)"
}

configure_doh_blocking() {
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[BLOCK_DOH]}" ]]; then
            read -r -p "Block DNS-over-HTTPS (DoH) to enforce DNS spoofing? (y/N): " enable_doh_blocking
            if [[ "${enable_doh_blocking}" =~ ^[Yy]$ ]]; then
                DEFAULTS[BLOCK_DOH]=true
            elif [[ "${enable_doh_blocking}" =~ ^[Nn]$ ]]; then
                DEFAULTS[BLOCK_DOH]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[BLOCK_DOH]}" == true ]] || return

    log "Configuring DNS-over-HTTPS (DoH) blocking..."
    
    # Block HTTPS traffic to known DoH providers
    for doh_ip in "${DOH_PROVIDERS[@]}"; do
        IPTABLES_RULES+=(
            "iptables -I FORWARD -d ${doh_ip} -p tcp --dport 443 -j REJECT --reject-with tcp-reset"
        )
        log "Blocking DoH provider: ${doh_ip}"
    done
    
    # Redirect all DNS queries (port 53) to local dnsmasq server
    IPTABLES_RULES+=(
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p udp --dport 53 -j REDIRECT --to-port 53"
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 53 -j REDIRECT --to-port 53"
    )
    
    log "DoH blocking enabled. All DNS traffic will be redirected to local DNS server."
}

