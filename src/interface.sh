#!/bin/bash

configure_interface() {
    # In interactive mode, ask whether to use ethernet AP mode if not already decided
    if [[ "${INTERACTIVE_MODE}" == true && -z "${ARG[ETHERNET_MODE]}" ]]; then
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

    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ -z "${ARG[CLONE_SSID]}" ]]; then
            mapfile -t wifi_aps < <(get_wifi_ssids "${DEFAULTS[INTERFACE]}")
            DEFAULTS[CLONE_SSID]=$(select_from_list "Select Access Point for cloning interface:" "${wifi_aps[@]}")
            log "Selected Access Point for cloning: ${DEFAULTS[CLONE_SSID]}"
        else
            log "Using specified Access Point for cloning: ${DEFAULTS[CLONE_SSID]}"
        fi
    elif [[ -n "${ARG[CLONE_SSID]}" ]]; then
        log "Using specified Access Point for cloning: ${DEFAULTS[CLONE_SSID]}"
    else
        log "No Access Point specified for cloning"
    fi

    [[ -n "${DEFAULTS[CLONE_SSID]}" ]] || {
        warn "No Access Point specified for cloning, skipping interface cloning"
        DEFAULTS[CLONE]=false
        return 0
    }

    IFS="|" read -r ssid channel mac ap_security < <(get_ap_info "${DEFAULTS[CLONE_SSID]}" "${DEFAULTS[INTERFACE]}")

    if [[ -z "${ssid}" || -z "${channel}" ]]; then
        error "Clone target '${DEFAULTS[CLONE_SSID]}' was not found in the scan results on ${DEFAULTS[INTERFACE]}." \
              "Ensure the target AP is in range and try again."
    fi

    if [[ -z "${ARG[SSID]}" ]]; then
        DEFAULTS[SSID]="$ssid"
    else
        log "Preserving specified SSID: ${DEFAULTS[SSID]} (ignoring clone SSID: $ssid)"
    fi

    if [[ -z "${ARG[CHANNEL]}" ]]; then
        DEFAULTS[CHANNEL]="$channel"
    else
        log "Preserving specified Channel: ${DEFAULTS[CHANNEL]} (ignoring clone Channel: $channel)"
    fi

    if [[ -z "${ARG[MAC]}" ]]; then
        DEFAULTS[MAC]="$mac"
    else
        log "Preserving specified MAC: ${DEFAULTS[MAC]} (ignoring clone MAC: $mac)"
    fi

	if [[ -z "${ARG[SECURITY]}" ]]; then
		DEFAULTS[SECURITY]="${ap_security:-open}"
		log "Cloned security type: ${DEFAULTS[SECURITY]}"
	else
		log "Preserving specified security type: ${DEFAULTS[SECURITY]} (ignoring clone security: ${ap_security})"
	fi

	if [[ "${DEFAULTS[SECURITY]}" != "open" && -z "${DEFAULTS[PASSWORD]}" ]]; then
		warn "Cloned network '${ssid}' uses ${DEFAULTS[SECURITY]} — its password can't be sniffed from a scan."
		warn "You must supply the real password with --password (or you'll be prompted if running interactively)."
	fi

	log "Cloning interface ${DEFAULTS[INTERFACE]} with SSID: ${DEFAULTS[SSID]}, Channel: ${DEFAULTS[CHANNEL]}, MAC: ${DEFAULTS[MAC]}, Security: ${DEFAULTS[SECURITY]}"
}