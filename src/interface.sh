#!/bin/bash

configure_interface() {
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
            # Try to auto-detect if not specified
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

configure_mac_in_interactive() {
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

    IFS="|" read -r ssid channel mac < <(get_ap_info "${DEFAULTS[CLONE_SSID]}" "${DEFAULTS[INTERFACE]}")
    
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


    log "Cloning interface ${DEFAULTS[INTERFACE]} with SSID: ${DEFAULTS[SSID]}, Channel: ${DEFAULTS[CHANNEL]}, MAC: ${DEFAULTS[MAC]}"
}


