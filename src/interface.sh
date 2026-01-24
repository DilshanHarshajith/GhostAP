#!/bin/bash

configure_interface() {
    log "Configuring wireless interface..."

    local interfaces
    mapfile -t interfaces < <(get_wireless_interfaces)

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[INTERFACE]}" ]]; then
            INTERFACE=$(select_from_list "Select wireless interface:" "${interfaces[@]}")
            DEFAULTS[INTERFACE]="${INTERFACE}"
            log "Selected interface: ${INTERFACE}"
        else
            INTERFACE="${DEFAULTS[INTERFACE]}"
            log "Using specified interface: ${INTERFACE}"
        fi
    else
        if [[ -n "${ARG[INTERFACE]}" ]]; then
            INTERFACE="${DEFAULTS[INTERFACE]}"
            log "Selected interface: ${INTERFACE}"
        else
            # Try to auto-detect if not specified
            local auto_interface
            auto_interface=$(get_wireless_interfaces | head -n 1)
            if [[ -n "${auto_interface}" ]]; then
                INTERFACE="${auto_interface}"
                DEFAULTS[INTERFACE]="${INTERFACE}"
                warn "No wireless interface specified. Automatically selected: ${INTERFACE}"
            else
                error "No wireless interface found or specified. Use -i <interface>"
            fi
        fi
    fi

    if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
        error "Interface ${INTERFACE} not found"
    fi

    if [[ ! -e "/sys/class/net/${INTERFACE}/wireless" ]]; then
        warn "Interface ${INTERFACE} may not be a wireless interface"
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
            mapfile -t wifi_aps < <(get_wifi_ssids "${INTERFACE}")
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

    IFS="|" read -r ssid channel mac < <(get_ap_info "${DEFAULTS[CLONE_SSID]}" "${INTERFACE}")
    
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
    
    DEFAULTS[MAC]="$mac"

    log "Cloning interface ${INTERFACE} with SSID: ${DEFAULTS[SSID]}, Channel: ${DEFAULTS[CHANNEL]}, MAC: ${DEFAULTS[MAC]}"
}


