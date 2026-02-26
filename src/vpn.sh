#!/bin/bash

configure_vpn() {
    local vpn_config="${DEFAULTS[VPN_CONFIG]}"
    
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[VPN_ROUTING]}" ]]; then
            read -r -p "Enable VPN routing (y/N): " enable_vpn
            if [[ "${enable_vpn}" =~ ^[Yy]$ ]]; then
                DEFAULTS[VPN_ROUTING]=true
                read -r -p "Path to VPN config (.ovpn or .conf) [Leave empty to pick an existing interface]: " vpn_config
                DEFAULTS[VPN_CONFIG]="${vpn_config}"
            else
                DEFAULTS[VPN_ROUTING]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[VPN_ROUTING]}" == true ]] || return 0

    log "Configuring VPN routing for AP..."

    if [[ -n "${vpn_config}" ]]; then
        if [[ ! -f "${vpn_config}" ]]; then
             error "VPN config file not found: ${vpn_config}"
        fi
        
        # Start VPN client
        if [[ "${vpn_config}" == *.ovpn ]]; then
            log "Starting OpenVPN with ${vpn_config}"
            # --route-nopull prevents OpenVPN from hijacking host default route
            openvpn --config "${vpn_config}" --route-nopull --daemon --writepid "${TMP_DIR}/openvpn.pid"
            
            # Wait for tun adapter to appear
            log "Waiting for OpenVPN interface..."
            local attempts=0
            while [[ $attempts -lt 15 ]]; do
                # Extract PID
                if [[ -f "${TMP_DIR}/openvpn.pid" ]]; then
                    VPN_PID=$(cat "${TMP_DIR}/openvpn.pid")
                    PIDS+=("${VPN_PID}")
                fi
                
                # Check for tun interface created by this config
                # As openvpn might create tun0, tun1 etc.
                # A simple check is to find the newest tun interface or just check if any new tun exists
                local new_tun=$(ip link show | grep -o 'tun[0-9]*' | tail -n1)
                if [[ -n "${new_tun}" ]]; then
                    VPN_INTERFACE="${new_tun}"
                    break
                fi
                sleep 1
                ((attempts++))
            done
            
            if [[ -z "${VPN_INTERFACE}" ]]; then
                error "OpenVPN failed to create a tun interface in time."
            fi
            
        elif [[ "${vpn_config}" == *.conf ]]; then
            log "Starting WireGuard with ${vpn_config}"
            # Ensure name is short enough for wg-quick (ifname length limit is 15 chars)
            # wg_ap is 5 chars
            VPN_TEMP_CONF="${TMP_DIR}/wg_ap.conf"
            cp "${vpn_config}" "${VPN_TEMP_CONF}"
            
            # Append Table = off to prevent WireGuard from changing host default route
            if ! grep -q -i "Table\s*=\s*off" "${VPN_TEMP_CONF}"; then
                 # Insert under [Interface]
                 sed -i '/^\[Interface\]/a Table = off' "${VPN_TEMP_CONF}"
            fi
            
            # wg-quick up takes the filename as interface name
            local wg_iface=$(basename "${VPN_TEMP_CONF}" .conf)
            wg-quick up "${VPN_TEMP_CONF}" || error "Failed to start WireGuard."
            VPN_INTERFACE="${wg_iface}"
        else
            error "Unsupported VPN config extension. Must be .ovpn or .conf"
        fi
        
    else
        # No config provided, let user select from existing VPN interfaces
        local interfaces
        mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | egrep "(tun|wg|proton|tap)")
        if [[ ${#interfaces[@]} -eq 0 ]]; then
            error "No existing VPN interfaces found and no config provided."
        fi
        if [[ "${INTERACTIVE_MODE}" == true ]]; then
            VPN_INTERFACE=$(select_from_list "Select existing VPN interface for routing:" "${interfaces[@]}")
        else
            VPN_INTERFACE="${interfaces[0]}"
            warn "No VPN config provided, auto-selected existing interface: ${VPN_INTERFACE}"
        fi
    fi

    # Check connectivity on VPN interface momentarily
    log "Checking connectivity on ${VPN_INTERFACE}..."
    sleep 2 # Short delay to let the interface assign IP
    
    # Establish Policy Based Routing
    log "Setting up Policy Based Routing (PBR) for ${INTERFACE} -> ${VPN_INTERFACE}"
    
    # 1. Sysctl forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || warn "Failed to enable IP forwarding"
    
    # 2. Add routing table 200 rule for AP traffic
    ip rule add iif "${INTERFACE}" lookup 200 2>/dev/null || true
    
    # 3. Add default route in table 200 via the VPN interface
    ip route add default dev "${VPN_INTERFACE}" table 200 2>/dev/null || true
    
    # 4. Flush cache
    ip route flush cache
    
    # 5. IPTables NAT and Forwarding
    # Masquerade traffic going out of the VPN interface
    IPTABLES_RULES+=(
        "iptables -t nat -A POSTROUTING -o ${VPN_INTERFACE} -j MASQUERADE"
        "iptables -A FORWARD -i ${VPN_INTERFACE} -o ${INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "iptables -A FORWARD -i ${INTERFACE} -o ${VPN_INTERFACE} -j ACCEPT"
        # AP client-to-client traffic
        "iptables -A FORWARD -i ${INTERFACE} -o ${INTERFACE} -j ACCEPT"
        # VPN Kill switch: drop any traffic from AP that is NOT going to VPN interface
        "iptables -A FORWARD -i ${INTERFACE} -j DROP"
    )
    
    log "VPN routing configured successfully on ${VPN_INTERFACE}"
}

cleanup_vpn() {
    log "Cleaning up VPN..."

    # Shutdown VPN if active
    if [[ "${DEFAULTS[VPN_ROUTING]}" == true && -n "${VPN_INTERFACE:-}" ]]; then
        log "Shutting down VPN interface: ${VPN_INTERFACE}"
        if [[ -f "${TMP_DIR}/openvpn.pid" ]]; then
            log "Stopping OpenVPN via PID..."
            kill -15 "$(<"${TMP_DIR}/openvpn.pid")" 2>/dev/null || true
            rm -f "${TMP_DIR}/openvpn.pid"
        fi
        
        # Flush custom routing table 200
        ip rule del iif "${INTERFACE}" lookup 200 2>/dev/null || true
        ip route flush table 200 2>/dev/null || true
    fi
    
    # Fallback/catch-all cleanup
    if [[ -n "${VPN_PID:-}" ]] && kill -0 "${VPN_PID}" 2>/dev/null; then
        kill "${VPN_PID}" 2>/dev/null || true
    fi
    if [[ -n "${VPN_TEMP_CONF:-}" && -f "${VPN_TEMP_CONF}" ]]; then
        wg-quick down "${VPN_TEMP_CONF}" 2>/dev/null || true
        rm -f "${VPN_TEMP_CONF}"
    fi
    if [[ "${DEFAULTS[VPN_ROUTING]:-false}" == true ]]; then
        ip rule del iif "${INTERFACE}" lookup 200 2>/dev/null || true
        ip route flush table 200 2>/dev/null || true
    fi
}
