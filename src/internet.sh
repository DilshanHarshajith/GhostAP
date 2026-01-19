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
            SOURCE_INTERFACE="${DEFAULTS[SOURCE_INTERFACE]}"
        else
            mapfile -t interfaces < <(get_internet_interfaces | grep -v "^${INTERFACE}$")
            if [[ ${#interfaces[@]} -eq 0 ]]; then
                DEFAULTS[INTERNET_SHARING]=false
                return
            fi
            SOURCE_INTERFACE=$(select_from_list "Source interface for internet:" "${interfaces[@]}")            
        fi
    elif [[ -n "${ARG[SOURCE_INTERFACE]}" ]]; then
        SOURCE_INTERFACE="${DEFAULTS[SOURCE_INTERFACE]}"
    else
        mapfile -t interfaces < <(get_internet_interfaces | grep -v "^${INTERFACE}$")
        if [[ ${#interfaces[@]} -eq 0 ]]; then
            DEFAULTS[INTERNET_SHARING]=false
            return
        fi
        SOURCE_INTERFACE="${interfaces[0]}"
        [[ -n "${SOURCE_INTERFACE}" ]] || { DEFAULTS[INTERNET_SHARING]=false; return; }
        DEFAULTS[SOURCE_INTERFACE]="${SOURCE_INTERFACE}"
    fi

    DEFAULTS[SOURCE_INTERFACE]="${SOURCE_INTERFACE}"

    if ! ping -I "${SOURCE_INTERFACE}" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        warn "No internet connectivity detected on source interface ${SOURCE_INTERFACE}"
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
        if [[ -n "${SOURCE_INTERFACE}" ]]; then
            log "Enabling internet sharing..."
            
            if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null; then
                warn "Failed to enable IP forwarding"
            fi
            
            IPTABLES_RULES+=(
                "iptables -t nat -I POSTROUTING -o ${SOURCE_INTERFACE} -j MASQUERADE"
                "iptables -I FORWARD -i ${SOURCE_INTERFACE} -o ${INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT"
                "iptables -I FORWARD -i ${INTERFACE} -o ${SOURCE_INTERFACE} -j ACCEPT"
            )
            
            if command -v tc >/dev/null; then
                tc qdisc add dev "${INTERFACE}" root handle 1: htb default 30 2>/dev/null || true
                tc class add dev "${INTERFACE}" parent 1: classid 1:1 htb rate 100mbit 2>/dev/null || true
                tc class add dev "${INTERFACE}" parent 1:1 classid 1:10 htb rate 50mbit ceil 100mbit 2>/dev/null || true
                tc class add dev "${INTERFACE}" parent 1:1 classid 1:20 htb rate 30mbit ceil 80mbit 2>/dev/null || true
                tc class add dev "${INTERFACE}" parent 1:1 classid 1:30 htb rate 20mbit ceil 50mbit 2>/dev/null || true
            fi
        fi
    fi
}
