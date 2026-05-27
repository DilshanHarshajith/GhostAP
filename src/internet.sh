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
            # List all up interfaces immediately — no detection delay
            mapfile -t all_ifaces < <(ip -o link show up | awk -F': ' '{print $2}' | sed 's/@.*//' \
                | grep -v "^lo$" | grep -v "^${DEFAULTS[INTERFACE]}$")

            if [[ ${#all_ifaces[@]} -eq 0 ]]; then
                warn "No available interfaces found for internet sharing."
                DEFAULTS[INTERNET_SHARING]=false
                return
            fi

            local choice
            choice=$(select_from_list "Source interface for internet:" \
                "${all_ifaces[@]}" \
                "Detect Best (auto-select fastest)" \
                "Scan All (list internet-connected, ordered by speed)")

            case "${choice}" in

                "Detect Best (auto-select fastest)")
                    log "Detecting best upstream interface..."
                    mapfile -t ranked < <(get_interfaces_ranked_by_speed)
                    if [[ ${#ranked[@]} -gt 0 ]]; then
                        # ranked[0] is fastest — strip the "(Xms)" annotation
                        DEFAULTS[SOURCE_INTERFACE]=$(awk '{print $1}' <<< "${ranked[0]}")
                        log "Best interface detected: ${DEFAULTS[SOURCE_INTERFACE]}"
                    else
                        warn "No internet-connected interface found. Internet sharing will be disabled."
                        DEFAULTS[INTERNET_SHARING]=false
                        return
                    fi
                    ;;

                "Scan All (list internet-connected, ordered by speed)")
                    log "Scanning interfaces for internet connectivity (this may take a moment)..."
                    mapfile -t ranked < <(get_interfaces_ranked_by_speed)
                    if [[ ${#ranked[@]} -eq 0 ]]; then
                        warn "No internet-connected interfaces found. Internet sharing will be disabled."
                        DEFAULTS[INTERNET_SHARING]=false
                        return
                    fi
                    local ranked_choice
                    ranked_choice=$(select_from_list "Select internet interface (fastest first):" "${ranked[@]}")
                    # Strip the "(Xms)" annotation before storing
                    DEFAULTS[SOURCE_INTERFACE]=$(awk '{print $1}' <<< "${ranked_choice}")
                    ;;

                *)
                    # User picked a specific interface directly — use as-is
                    DEFAULTS[SOURCE_INTERFACE]="${choice}"
                    ;;
            esac
        fi
    elif [[ -n "${ARG[SOURCE_INTERFACE]}" ]]; then
        log "Using specified source interface: ${DEFAULTS[SOURCE_INTERFACE]}"
    else
        # Non-interactive: auto-select best interface
        mapfile -t ranked < <(get_interfaces_ranked_by_speed)
        if [[ ${#ranked[@]} -gt 0 ]]; then
            DEFAULTS[SOURCE_INTERFACE]=$(awk '{print $1}' <<< "${ranked[0]}")
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

            enable_forwarding

            if [[ "${DEFAULTS[VPN_ROUTING]}" == true ]]; then
                log "VPN routing is active. Skipping cleartext MASQUERADE/FORWARD rules to prevent VPN leaks."
            else
                IPTABLES_RULES+=(
                    "iptables -t nat -I POSTROUTING -o ${DEFAULTS[SOURCE_INTERFACE]} -j MASQUERADE"
                    "iptables -I FORWARD -i ${DEFAULTS[SOURCE_INTERFACE]} -o ${DEFAULTS[INTERFACE]} -m state --state RELATED,ESTABLISHED -j ACCEPT"
                    "iptables -I FORWARD -i ${DEFAULTS[INTERFACE]} -o ${DEFAULTS[SOURCE_INTERFACE]} -j ACCEPT"
                )
            fi

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

get_interfaces_ranked_by_speed() {
    # Returns internet-connected interfaces sorted by ascending ping time (fastest first).
    # Each entry is formatted as "iface  (Xms)" for display.
    local interfaces
    mapfile -t interfaces < <(ip -o link show up | awk -F': ' '{print $2}' | sed 's/@.*//' \
        | grep -v "^lo$" | grep -v "^${DEFAULTS[INTERFACE]}$")

    local -a results=()

    for iface in "${interfaces[@]}"; do
        local ping_time
        ping_time=$(ping -I "${iface}" -c 2 -W 1 8.8.8.8 2>/dev/null \
            | awk -F'/' '/^rtt/ {printf "%.1f", $5}')
        if [[ -n "${ping_time}" ]]; then
            results+=("${ping_time} ${iface}")
        fi
    done

    # Sort by ping time (numeric ascending) and format for display
    printf '%s\n' "${results[@]}" \
        | sort -k1 -n \
        | awk '{printf "%s  (%sms)\n", $2, $1}'
}