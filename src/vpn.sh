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

    # FIX #6: Warn early if VPN routing and internet sharing are both active,
    # since the kill switch DROP rule appended here could conflict with FORWARD
    # ACCEPT rules added later by configure_internet_sharing.
    if [[ "${DEFAULTS[INTERNET_SHARING]}" == true ]]; then
        warn "VPN routing and internet sharing are both enabled. The VPN kill switch" \
             "will block non-VPN forwarding. Disable internet sharing or remove the" \
             "kill switch if you need split routing."
    fi

    log "Configuring VPN routing for AP..."

    # 1. Start VPN if config is provided and no interface is pre-selected
    if [[ -z "${vpn_interface}" && -n "${vpn_config}" ]]; then
        if [[ ! -f "${vpn_config}" ]]; then
            error "VPN config file not found: ${vpn_config}"
        fi

        # Save current tun interfaces to detect the new one
        local old_tuns
        old_tuns=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(tun|wg|tap)" | sort)

        if [[ "${vpn_config}" == *.ovpn ]]; then
            log "Starting OpenVPN with ${vpn_config}"
            local openvpn_cmd=(openvpn --config "$vpn_config" --daemon --writepid "${TMP_DIR}/openvpn.pid")

            if grep -q "^auth-user-pass" "$vpn_config"; then
                # FIX #2: Guard credential prompt — only prompt in interactive mode.
                # In non-interactive mode require credentials to be passed via --vpn-creds.
                if [[ -z "${vpn_creds}" ]]; then
                    if [[ "${INTERACTIVE_MODE}" != true ]]; then
                        error "OpenVPN config requires credentials. Pass them with --vpn-creds user:pass in non-interactive mode."
                    fi
                    while [[ -z "$vpn_creds" || ! "$vpn_creds" =~ ^[^:]+:[^:]+$ ]]; do
                        read -r -p "OpenVPN credentials [format: username:password]: " vpn_creds
                    done
                fi

                local vpn_user="${vpn_creds%%:*}"
                local vpn_pass="${vpn_creds#*:}"
                local creds_file="${TMP_DIR}/openvpn_creds.txt"
                printf '%s\n%s\n' "$vpn_user" "$vpn_pass" > "$creds_file"
                chmod 600 "$creds_file"
                openvpn_cmd+=(--auth-user-pass "$creds_file")
            fi

            "${openvpn_cmd[@]}"

            # FIX #5: Give OpenVPN a moment to start then verify it didn't crash immediately.
            sleep 1
            if [[ -f "${TMP_DIR}/openvpn.pid" ]]; then
                VPN_PID=$(cat "${TMP_DIR}/openvpn.pid")
                # FIX #1: Register PID exactly once, outside the detection loop.
                PIDS+=("${VPN_PID}")
                if ! kill -0 "${VPN_PID}" 2>/dev/null; then
                    error "OpenVPN process (PID ${VPN_PID}) died immediately. Check your config and credentials."
                fi
            else
                error "OpenVPN did not write a PID file. It may have failed to start."
            fi

            log "Waiting for OpenVPN interface..."
            local attempts=0
            local new_tun=""
            while [[ $attempts -lt 15 ]]; do
                local current_tuns
                current_tuns=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(tun|wg|tap)" | sort)
                new_tun=$(comm -13 <(echo "$old_tuns") <(echo "$current_tuns") | head -n1)

                if [[ -n "${new_tun}" ]]; then
                    vpn_interface="${new_tun}"
                    DEFAULTS[VPN_INTERFACE]="${vpn_interface}"
                    break
                fi

                # FIX #5 (cont): Also abort early if OpenVPN died during the wait.
                if ! kill -0 "${VPN_PID}" 2>/dev/null; then
                    error "OpenVPN process died while waiting for tun interface."
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
            # FIX #4: Restrict permissions on the WireGuard config immediately after
            # copying — it contains a private key and must not be world-readable.
            chmod 600 "${VPN_TEMP_CONF}"

            wg-quick up "${VPN_TEMP_CONF}" || error "Failed to start WireGuard."

            # FIX #7: Derive the interface name from the config filename rather than
            # hardcoding it, so refactors to TMP_DIR or filename stay consistent.
            vpn_interface="$(basename "${VPN_TEMP_CONF}" .conf)"
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
        # FIX #9: In interactive mode, let the user pick when multiple exist.
        # In non-interactive mode with multiple interfaces, abort to avoid silent misrouting.
        if [[ ${#interfaces[@]} -gt 1 ]]; then
            if [[ "${INTERACTIVE_MODE}" == true ]]; then
                vpn_interface=$(select_from_list "Multiple VPN interfaces found. Select one:" "${interfaces[@]}")
            else
                error "Multiple VPN interfaces found (${interfaces[*]}). Specify one with --vpn-interface."
            fi
        else
            vpn_interface="${interfaces[0]}"
            warn "Auto-selected existing VPN interface: ${vpn_interface}"
        fi
        DEFAULTS[VPN_INTERFACE]="${vpn_interface}"
    fi

    # FIX #3: Actually verify connectivity on the VPN interface instead of just sleeping.
    log "Checking connectivity on ${vpn_interface}..."
    local connected=false
    for i in {1..10}; do
        if ping -c1 -W1 -I "${vpn_interface}" 8.8.8.8 &>/dev/null; then
            connected=true
            log "VPN connectivity confirmed on ${vpn_interface} (attempt ${i})."
            break
        fi
        sleep 1
    done
    if [[ "${connected}" == false ]]; then
        warn "No ping response through ${vpn_interface} after 10 seconds. Routing may still work, but check your VPN connection."
    fi

    # Establish Policy Based Routing
    log "Setting up Policy Based Routing (PBR) for ${DEFAULTS[INTERFACE]} -> ${vpn_interface}"

    # 1. Enable forwarding
    enable_forwarding

    # 2. Add routing table 200 rule for AP traffic and marked host traffic
    ip rule add iif "${DEFAULTS[INTERFACE]}" lookup 200 2>/dev/null || true
    ip rule add fwmark 0x100 lookup 200 2>/dev/null || true

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
        "iptables -A FORWARD -i ${DEFAULTS[INTERFACE]} ! -o ${vpn_interface} -j DROP"
        # Prevent marked traffic from leaking via local interfaces
        "iptables -A OUTPUT -m mark --mark 0x100 ! -o ${vpn_interface} -j DROP"
    )

    log "VPN routing configured successfully on ${vpn_interface}"
}

cleanup_vpn() {
    log "Cleaning up VPN..."

    if [[ "${DEFAULTS[VPN_ROUTING]:-false}" == true ]]; then
        # 1. Flush custom routing table 200 and rules
        ip rule del iif "${DEFAULTS[INTERFACE]}" lookup 200 2>/dev/null || true
        ip rule del fwmark 0x100 lookup 200 2>/dev/null || true
        ip route flush table 200 2>/dev/null || true

        # 2. Shutdown OpenVPN if started by us
        # FIX #8: Wait for graceful SIGTERM, then force-kill if still running.
        if [[ -f "${TMP_DIR}/openvpn.pid" ]]; then
            local pid
            pid=$(cat "${TMP_DIR}/openvpn.pid")
            log "Stopping OpenVPN (PID: ${pid})..."
            kill -15 "${pid}" 2>/dev/null || true
            # Wait up to 5 seconds for a clean exit
            local waited=0
            while kill -0 "${pid}" 2>/dev/null && [[ $waited -lt 5 ]]; do
                sleep 1
                ((waited++))
            done
            if kill -0 "${pid}" 2>/dev/null; then
                warn "OpenVPN did not exit after SIGTERM — force killing (PID: ${pid})"
                kill -9 "${pid}" 2>/dev/null || true
            fi
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