#!/bin/bash

configure_interface() {
    # If the user already specified an interface, infer AP mode directly from
    # it instead of asking — the interface type tells us which mode applies.
    # --eth-ap still wins if explicitly passed alongside -i.
    if [[ -n "${ARG[INTERFACE]}" && -z "${ARG[ETHERNET_MODE]}" ]]; then
        if [[ -e "/sys/class/net/${DEFAULTS[INTERFACE]}/wireless" ]]; then
            DEFAULTS[ETHERNET_MODE]=false
        else
            DEFAULTS[ETHERNET_MODE]=true
            log "Interface ${DEFAULTS[INTERFACE]} has no wireless capability — enabling Ethernet AP mode automatically."
        fi
    elif [[ "${INTERACTIVE_MODE}" == true && -z "${ARG[ETHERNET_MODE]}" ]]; then
        read -r -p "Use ethernet AP mode? (y/N): " eth_mode_input
        if [[ "${eth_mode_input}" =~ ^[Yy]$ ]]; then
            DEFAULTS[ETHERNET_MODE]=true
            log "Ethernet AP mode enabled."
        fi
    fi

    if [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]]; then
        _configure_ethernet_interface
    else
        _configure_wireless_interface
    fi
}

_configure_wireless_interface() {
    log "Configuring wireless interface..."

    local interfaces
    mapfile -t interfaces < <(get_wireless_interfaces)

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[INTERFACE]}" ]]; then
            DEFAULTS[INTERFACE]=$(select_from_list "Select wireless interface:" "${interfaces[@]}")
            log "Selected interface: ${DEFAULTS[INTERFACE]}"
        else
            log "Using specified interface: ${DEFAULTS[INTERFACE]}"
        fi
    else
        if [[ -n "${ARG[INTERFACE]}" ]]; then
            log "Selected interface: ${DEFAULTS[INTERFACE]}"
        else
            local auto_interface
            auto_interface=$(get_wireless_interfaces | head -n 1)
            if [[ -n "${auto_interface}" ]]; then
                DEFAULTS[INTERFACE]="${auto_interface}"
                warn "No wireless interface specified. Automatically selected: ${DEFAULTS[INTERFACE]}"
            else
                error "No wireless interface found or specified. Use -i <interface>"
            fi
        fi
    fi

    if ! ip link show "${DEFAULTS[INTERFACE]}" >/dev/null 2>&1; then
        error "Interface ${DEFAULTS[INTERFACE]} not found"
    fi

    if [[ ! -e "/sys/class/net/${DEFAULTS[INTERFACE]}/wireless" ]]; then
        warn "Interface ${DEFAULTS[INTERFACE]} may not be a wireless interface"
    fi
}

_configure_ethernet_interface() {
    log "Configuring ethernet interface (Ethernet AP mode)..."
    log "In this mode there is no radio for GhostAP to manage: the port either"
    log "faces a downstream router (its own WiFi radio serves the clients) or"
    log "a single PC/laptop plugged in directly via a straight ethernet cable."
    log "GhostAP manages DHCP, NAT, and all features on that ethernet port either way."

    local interfaces
    mapfile -t interfaces < <(get_ethernet_interfaces)

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[INTERFACE]}" ]]; then
            DEFAULTS[INTERFACE]=$(select_from_list "Select ethernet interface (facing downstream router or directly connected PC):" "${interfaces[@]}")
            log "Selected interface: ${DEFAULTS[INTERFACE]}"
        else
            log "Using specified interface: ${DEFAULTS[INTERFACE]}"
        fi
    else
        if [[ -n "${ARG[INTERFACE]}" ]]; then
            log "Using specified ethernet interface: ${DEFAULTS[INTERFACE]}"
        else
            local auto_interface
            auto_interface=$(get_ethernet_interfaces | head -n 1)
            if [[ -n "${auto_interface}" ]]; then
                DEFAULTS[INTERFACE]="${auto_interface}"
                warn "No ethernet interface specified. Automatically selected: ${DEFAULTS[INTERFACE]}"
            else
                error "No ethernet interface found. Use -i <interface>"
            fi
        fi
    fi

    if ! ip link show "${DEFAULTS[INTERFACE]}" >/dev/null 2>&1; then
        error "Interface ${DEFAULTS[INTERFACE]} not found"
    fi

    # Sanity check: warn if user accidentally picked a wireless iface in eth mode
    if [[ -e "/sys/class/net/${DEFAULTS[INTERFACE]}/wireless" ]]; then
        warn "Interface ${DEFAULTS[INTERFACE]} appears to be wireless, but --eth-ap mode was selected."
        warn "This is unusual. Continue only if you know what you are doing."
    fi

    log "Ethernet AP interface set to: ${DEFAULTS[INTERFACE]}"
    log "NOTE: If a downstream router is on the other end, put it in bridge/AP mode"
    log "(disable its DHCP and NAT) so that GhostAP's DHCP and features reach the WiFi"
    log "clients directly. If it only supports router mode, clients will be"
    log "double-NATted and DNS spoofing / proxy features will only affect the"
    log "router-to-GhostAP leg. If instead a single PC is plugged directly into this"
    log "port via ethernet cable, no extra config is needed — just set that PC's NIC"
    log "to DHCP and GhostAP will hand it an address, gateway, and full interface access."
}

configure_mac_in_interactive() {
    [[ "${DEFAULTS[ETHERNET_MODE]}" == false ]] || return 0
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[MAC]}" && "${DEFAULTS[CLONE]}" != true ]]; then
            read -r -p "Custom MAC address for AP (leave blank for default): " user_mac
            if [[ -n "${user_mac}" ]]; then
                if validate_mac "${user_mac}"; then
                    DEFAULTS[MAC]="${user_mac}"
                    log "Custom MAC address set: ${DEFAULTS[MAC]}"
                else
                    warn "Invalid MAC address format. Using default."
                fi
            fi
        fi
    fi
}


configure_clone(){
    [[ "${DEFAULTS[ETHERNET_MODE]}" == false ]] || return 0

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[CLONE]}" ]]; then
            read -r -p "Enable interface cloning? (y/N): " enable_clone
            if [[ "${enable_clone}" =~ ^[Yy]$ ]]; then
                DEFAULTS[CLONE]=true
                log "Interface cloning enabled."
            elif [[ "${enable_clone}" =~ ^[Nn]$ ]]; then
                DEFAULTS[CLONE]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[CLONE]}" == true ]] || return 0
    log "Configuring interface cloning..."

    # An explicit target was already given (--clone "SSID", or loaded from
    # a saved config) — resolve it directly via a scan instead of asking.
    if [[ -n "${ARG[CLONE_SSID]}" ]]; then
        log "Using specified Access Point for cloning: ${DEFAULTS[CLONE_SSID]}"
        if configure_clone_resolve_target "${DEFAULTS[CLONE_SSID]}"; then
            return 0
        fi
        error "Clone target '${DEFAULTS[CLONE_SSID]}' was not found in range on ${DEFAULTS[INTERFACE]}." \
              "Ensure the target AP is in range and try again."
    fi

    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        read -r -p "Run a live scan (SSID, channel, security, signal) to help pick a target? (y/N): " live_answer
        if [[ "${live_answer}" =~ ^[Yy]$ ]] && configure_clone_live_scan; then
            return 0
        fi

        if configure_clone_quick_scan; then
            return 0
        fi

        warn "No Access Point specified for cloning, skipping interface cloning"
        DEFAULTS[CLONE]=false
        return 0
    fi

    # Non-interactive, no explicit SSID — nothing to scan for automatically.
    warn "No Access Point specified for cloning, skipping interface cloning"
    DEFAULTS[CLONE]=false
}