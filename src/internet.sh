#!/bin/bash

configure_internet_sharing() {
    local interfaces

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[INTERNET_SHARING]}" ]]; then
            read -r -p "Enable internet sharing? (y/N): " enable_sharing
            if [[ "${enable_sharing}" =~ ^[Yy]$ ]]; then
                DEFAULTS[INTERNET_SHARING]=true
            elif [[ "${enable_sharing}" =~ ^[Nn]$ ]]; then
                DEFAULTS[INTERNET_SHARING]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[INTERNET_SHARING]}" == true ]] || return 0

    log "Configuring internet sharing..."

    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ -n "${ARG[SOURCE_INTERFACE]}" ]]; then
            log "Using specified source interface: ${DEFAULTS[SOURCE_INTERFACE]}"
        else
            mapfile -t interfaces < <(get_internet_interfaces | grep -v "^${DEFAULTS[INTERFACE]}$")
            if [[ ${#interfaces[@]} -eq 0 ]]; then
                DEFAULTS[INTERNET_SHARING]=false
                return
            fi
            DEFAULTS[SOURCE_INTERFACE]=$(select_from_list "Source interface for internet:" "${interfaces[@]}")            
        fi
    elif [[ -n "${ARG[SOURCE_INTERFACE]}" ]]; then
        log "Using specified source interface: ${DEFAULTS[SOURCE_INTERFACE]}"
    else
        # Auto-select best interface
        local best_iface
        best_iface=$(find_best_upstream_interface)
        if [[ -n "${best_iface}" ]]; then
            DEFAULTS[SOURCE_INTERFACE]="${best_iface}"
            warn "No source interface specified. Automatically selected: ${DEFAULTS[SOURCE_INTERFACE]}"
        else
             warn "No internet-connected interface found. Internet sharing will be disabled."
             DEFAULTS[INTERNET_SHARING]=false
             return
        fi
    fi


    if ! ping -I "${DEFAULTS[SOURCE_INTERFACE]}" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        warn "No internet connectivity detected on source interface ${DEFAULTS[SOURCE_INTERFACE]}"
    fi

    if [[ "${DEFAULTS[INTERNET_SHARING]}" == true ]]; then
        log "Internet sharing enabled"
        enable_internet_sharing
    else
        log "Internet sharing disabled"
    fi
}

enable_internet_sharing() {
    if [[ "${DEFAULTS[INTERNET_SHARING]}" == true ]]; then
        if [[ -n "${DEFAULTS[SOURCE_INTERFACE]}" ]]; then
            log "Enabling internet sharing..."
            
            if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null; then
                warn "Failed to enable IP forwarding"
            fi
            
            IPTABLES_RULES+=(
                "iptables -t nat -I POSTROUTING -o ${DEFAULTS[SOURCE_INTERFACE]} -j MASQUERADE"
                "iptables -I FORWARD -i ${DEFAULTS[SOURCE_INTERFACE]} -o ${DEFAULTS[INTERFACE]} -m state --state RELATED,ESTABLISHED -j ACCEPT"
                "iptables -I FORWARD -i ${DEFAULTS[INTERFACE]} -o ${DEFAULTS[SOURCE_INTERFACE]} -j ACCEPT"
            )
            
            if command -v tc >/dev/null; then
                tc qdisc add dev "${DEFAULTS[INTERFACE]}" root handle 1: htb default 30 2>/dev/null || true
                tc class add dev "${DEFAULTS[INTERFACE]}" parent 1: classid 1:1 htb rate 100mbit 2>/dev/null || true
                tc class add dev "${DEFAULTS[INTERFACE]}" parent 1:1 classid 1:10 htb rate 50mbit ceil 100mbit 2>/dev/null || true
                tc class add dev "${DEFAULTS[INTERFACE]}" parent 1:1 classid 1:20 htb rate 30mbit ceil 80mbit 2>/dev/null || true
                tc class add dev "${DEFAULTS[INTERFACE]}" parent 1:1 classid 1:30 htb rate 20mbit ceil 50mbit 2>/dev/null || true
            fi
        fi
    fi
}

find_best_upstream_interface() {
    local interfaces
    mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "^${DEFAULTS[INTERFACE]}$")
    
    local best_iface=""
    local best_ping=9999
    
    for iface in "${interfaces[@]}"; do
        # Check if interface is up
        if ip link show "${iface}" | grep -q "state UP"; then
             # Ping check.
             local ping_time
             ping_time=$(ping -I "${iface}" -c 1 -W 1 8.8.8.8 2>/dev/null | grep 'time=' | sed -E 's/.*time=([0-9.]+).*/\1/')
             
             if [[ -n "${ping_time}" ]]; then
                 # Compare floating point numbers using awk
                 if awk "BEGIN {exit !(${ping_time} < ${best_ping})}"; then
                     best_ping=${ping_time}
                     best_iface=${iface}
                 fi
             fi
        fi
    done
    
    echo "${best_iface}"
}
