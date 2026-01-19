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
    fi

    [[ "${DEFAULTS[DNS_SPOOFING]}" == true ]] || return

    log "Configuring DNS spoofing..."

    if [[ -n "${ARG[SPOOF_DOMAINS]}" ]]; then
        IFS='|' read -ra entries <<< "$SPOOF_DOMAINS"
        for spoof_entry in "${entries[@]}"; do
            if [[ "${spoof_entry}" =~ ^[^=]+=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "address=/${spoof_entry/=//}" >> "${DNSMASQ_CONF}"
                log "Added DNS spoof: ${spoof_entry}"
            else
                warn "Invalid format for DNS spoofing entry: ${entry}. Use Format: domain.com=192.168.1.1"
            fi
        done
    else
        while read -r -p "Enter domains to spoof (format: domain.com=192.168.1.1), empty line to finish: " spoof_entry && [[ -n "${spoof_entry}" ]]; do
            if [[ "${spoof_entry}" =~ ^[^=]+=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "address=/${spoof_entry/=//}" >> "${DNSMASQ_CONF}"
                log "Added DNS spoof: ${spoof_entry}"
            else
                echo "Invalid format. Use: domain.com=192.168.1.1"
            fi
        done
    fi

    log "DNS Spoofing Enabled. (configure manually in dnsmasq.conf if needed)"
}
