#!/bin/bash

configure_vpn() {
    local vpn_config="${DEFAULTS[VPN_CONFIG]}"
    local vpn_interface="${DEFAULTS[VPN_INTERFACE]}"
    local vpn_creds="${DEFAULTS[VPN_CREDS]}"
    
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[VPN_ROUTING]}" ]]; then
            read -r -p "Enable VPN routing (y/N): " enable_vpn
            if [[ "${enable_vpn}" =~ ^[Yy]$ ]]; then
                DEFAULTS[VPN_ROUTING]=true
            else
                DEFAULTS[VPN_ROUTING]=false
            fi
        fi
        
        if [[ "${DEFAULTS[VPN_ROUTING]}" == true && -z "${vpn_config}" && -z "${vpn_interface}" ]]; then
            echo "VPN Configuration Mode:"
            local modes=("Select existing VPN interface" "Provide VPN config file (.ovpn or .conf)")
            local choice=$(select_from_list "Choose an option:" "${modes[@]}")
            
            if [[ "${choice}" == "${modes[0]}" ]]; then
                local interfaces
                mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -E "(tun|wg|proton|tap)")
                if [[ ${#interfaces[@]} -eq 0 ]]; then
                    warn "No existing VPN interfaces found. Switching to config file mode."
                else
                    vpn_interface=$(select_from_list "Select VPN interface:" "${interfaces[@]}")
                    DEFAULTS[VPN_INTERFACE]="${vpn_interface}"
                fi
            fi
            
            if [[ -z "${vpn_interface}" ]]; then
                read -r -p "Path to VPN config (.ovpn or .conf): " vpn_config
                DEFAULTS[VPN_CONFIG]="${vpn_config}"
            fi
        fi
    fi

    [[ "${DEFAULTS[VPN_ROUTING]}" == true ]] || return 0

    log "Configuring VPN routing for AP..."

    # 1. Start VPN if config is provided and no interface is pre-selected
    if [[ -z "${vpn_interface}" && -n "${vpn_config}" ]]; then
        if [[ ! -f "${vpn_config}" ]]; then
             error "VPN config file not found: ${vpn_config}"
        fi
        
        # Save current tun interfaces to detect the new one
        local old_tuns=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(tun|wg|tap)" | sort)

        if [[ "${vpn_config}" == *.ovpn ]]; then
            log "Starting OpenVPN with ${vpn_config}"
            local openvpn_cmd=(openvpn --config "$vpn_config" --daemon --writepid "${TMP_DIR}/openvpn.pid")

            if grep -q "^auth-user-pass" "$vpn_config"; then
                while [[ -z "$vpn_creds" || ! "$vpn_creds" =~ ^[^:]+:[^:]+$ ]]; do
                    read -r -p "OpenVPN credentials [format: username:password]: " vpn_creds
                done

                local vpn_user="${vpn_creds%%:*}"
                local vpn_pass="${vpn_creds#*:}"
                local creds_file="${TMP_DIR}/openvpn_creds.txt"
                printf '%s\n%s\n' "$vpn_user" "$vpn_pass" > "$creds_file"
                chmod 600 "$creds_file"
                openvpn_cmd+=(--auth-user-pass "$creds_file")
            fi

            "${openvpn_cmd[@]}"
            
            log "Waiting for OpenVPN interface..."
            local attempts=0
            while [[ $attempts -lt 15 ]]; do
                if [[ -f "${TMP_DIR}/openvpn.pid" ]]; then
                    VPN_PID=$(cat "${TMP_DIR}/openvpn.pid")
                    PIDS+=("${VPN_PID}")
                fi
                
                local current_tuns=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(tun|wg|tap)" | sort)
                local new_tun=$(comm -13 <(echo "$old_tuns") <(echo "$current_tuns") | head -n1)
                
                if [[ -n "${new_tun}" ]]; then
                    vpn_interface="${new_tun}"
                    DEFAULTS[VPN_INTERFACE]="${vpn_interface}"
                    break
                fi
                sleep 1
                ((attempts++))
            done
            
            if [[ -z "${vpn_interface}" ]]; then
                error "OpenVPN failed to create a tun interface in time."
            fi
            
        elif [[ "${vpn_config}" == *.conf ]]; then
            log "Starting WireGuard with ${vpn_config}"
            VPN_TEMP_CONF="${TMP_DIR}/wg_ap.conf"
            cp "${vpn_config}" "${VPN_TEMP_CONF}"
            vpn_interface="wg_ap"
            wg-quick up "${VPN_TEMP_CONF}" || error "Failed to start WireGuard."
            DEFAULTS[VPN_INTERFACE]="${vpn_interface}"
        else
            error "Unsupported VPN config extension. Must be .ovpn or .conf"
        fi
    fi

    # 2. Use existing interface or auto-detect if still empty
    if [[ -z "${vpn_interface}" ]]; then
        local interfaces
        mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -E "(tun|wg|proton|tap)")
        if [[ ${#interfaces[@]} -eq 0 ]]; then
            error "No VPN interface detected and no config provided."
        fi
        vpn_interface="${interfaces[0]}"
        DEFAULTS[VPN_INTERFACE]="${vpn_interface}"
        warn "Auto-selected existing interface: ${vpn_interface}"
    fi

    # Check connectivity on VPN interface momentarily
    log "Checking connectivity on ${vpn_interface}..."
    sleep 2 
    
    # Establish Policy Based Routing
    log "Setting up Policy Based Routing (PBR) for ${DEFAULTS[INTERFACE]} -> ${vpn_interface}"
    
    # 1. Sysctl forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || warn "Failed to enable IP forwarding"
    
    # 2. Add routing table 200 rule for AP traffic
    ip rule add iif "${DEFAULTS[INTERFACE]}" lookup 200 2>/dev/null || true
    
    # 3. Add default route in table 200 via the VPN interface
    ip route add default dev "${vpn_interface}" table 200 2>/dev/null || true
    
    # 4. Flush cache
    ip route flush cache
    
    # 5. IPTables NAT and Forwarding
    IPTABLES_RULES+=(
        "iptables -t nat -A POSTROUTING -o ${vpn_interface} -j MASQUERADE"
        "iptables -A FORWARD -i ${vpn_interface} -o ${DEFAULTS[INTERFACE]} -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "iptables -A FORWARD -i ${DEFAULTS[INTERFACE]} -o ${vpn_interface} -j ACCEPT"
        "iptables -A FORWARD -i ${DEFAULTS[INTERFACE]} -o ${DEFAULTS[INTERFACE]} -j ACCEPT"
        # VPN Kill switch: drop any traffic from AP that is NOT going to VPN interface
        "iptables -A FORWARD -i ${DEFAULTS[INTERFACE]} -j DROP"
    )
    
    log "VPN routing configured successfully on ${vpn_interface}"
}

cleanup_vpn() {
    log "Cleaning up VPN..."

    if [[ "${DEFAULTS[VPN_ROUTING]:-false}" == true ]]; then
        # 1. Flush custom routing table 200 and rules
        ip rule del iif "${DEFAULTS[INTERFACE]}" lookup 200 2>/dev/null || true
        ip route flush table 200 2>/dev/null || true
        
        # 2. Shutdown OpenVPN if started by us
        if [[ -f "${TMP_DIR}/openvpn.pid" ]]; then
            local pid=$(cat "${TMP_DIR}/openvpn.pid")
            log "Stopping OpenVPN (PID: ${pid})..."
            kill -15 "${pid}" 2>/dev/null || true
            rm -f "${TMP_DIR}/openvpn.pid"
        fi

        # 3. Shutdown WireGuard if started by us
        if [[ -n "${VPN_TEMP_CONF:-}" && -f "${VPN_TEMP_CONF}" ]]; then
            log "Stopping WireGuard..."
            wg-quick down "${VPN_TEMP_CONF}" 2>/dev/null || true
            rm -f "${VPN_TEMP_CONF}"
        fi
        
        # 4. Cleanup credentials
        [[ -f "${TMP_DIR}/openvpn_creds.txt" ]] && rm -f "${TMP_DIR}/openvpn_creds.txt"
    fi

    # Fallback PID cleanup
    if [[ -n "${VPN_PID:-}" ]] && kill -0 "${VPN_PID}" 2>/dev/null; then
        kill "${VPN_PID}" 2>/dev/null || true
    fi
}
