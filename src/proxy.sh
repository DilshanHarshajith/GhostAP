#!/bin/bash
# Proxy Modes:
# 1. TRANSPARENT_LOCAL: Intercepts traffic locally on AP. Clients -> AP (8080) -> Internet
# 2. TRANSPARENT_UPSTREAM (redsocks): Intercepts traffic and forwards to an external proxy. Clients -> AP -> Redsocks -> External Proxy -> Internet
# 3. REMOTE_DNAT (iptables): Simple DNAT forwarding to an external IP. Clients -> AP -> Destination (DNAT)

configure_proxy() {
    local proxy_mode="${DEFAULTS[PROXY_MODE]:-}"
    local proxy_host="${DEFAULTS[PROXY_HOST]}"
    local proxy_port="${DEFAULTS[PROXY_PORT]}"
    local proxy_type="${DEFAULTS[PROXY_TYPE]}"
    local proxy_user="${DEFAULTS[PROXY_USER]}"
    local proxy_pass="${DEFAULTS[PROXY_PASS]}"

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[PROXY_ENABLED]}" ]]; then
            read -r -p "Enable proxy routing? (y/N): " enable_proxy
            if [[ "${enable_proxy}" =~ ^[Yy]$ ]]; then
                DEFAULTS[PROXY_ENABLED]=true
            elif [[ "${enable_proxy}" =~ ^[Nn]$ ]]; then
                DEFAULTS[PROXY_ENABLED]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]] || return

    # Determine Proxy Mode
    if [[ ${INTERACTIVE_MODE} == true && -z "${ARG[PROXY_MODE]}" ]]; then
        echo "Select Proxy Mode:"
        local mode_choice
        mode_choice=$(select_from_list "Proxy Mode:" \
            "Local Transparent Proxy (Intercept traffic on this AP)" \
            "Upstream Proxy (Forward to external HTTP/SOCKS proxy via redsocks)" \
            "Remote Forwarding (Simple DNAT to external IP:Port)")
        
        case "${mode_choice}" in
            "Local Transparent Proxy"*) proxy_mode="TRANSPARENT_LOCAL" ;;
            "Upstream Proxy"*)          proxy_mode="TRANSPARENT_UPSTREAM" ;;
            "Remote Forwarding"*)       proxy_mode="REMOTE_DNAT" ;;
        esac
        
        # Only set if not already set by arg (double check, though the outer if checks this too)
        if [[ -z "${ARG[PROXY_MODE]}" ]]; then
             DEFAULTS[PROXY_MODE]="${proxy_mode}"
        fi
    fi

    case "${proxy_mode}" in
        "TRANSPARENT_LOCAL"|"TRANSPARENT_UPSTREAM"|"REMOTE_DNAT")
            ;;
        *)
            # Fallback/Default if arguments were odd
            proxy_mode="TRANSPARENT_LOCAL" # Default
            ;;
    esac
    DEFAULTS[PROXY_MODE]="${proxy_mode}"

    # Configure specific parameters
    if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" || "${proxy_mode}" == "REMOTE_DNAT" ]]; then
        if [[ -z "${ARG[PROXY_HOST]}" ]]; then
            while true; do
                read -r -p "Proxy/Remote Host IP: " user_input
                proxy_host="${user_input:-"${DEFAULTS[PROXY_HOST]}"}"
                if [[ -n "${proxy_host}" ]]; then break; fi # Validate IP?
            done
            DEFAULTS[PROXY_HOST]="${proxy_host}"
        fi
    fi

    if [[ -z "${ARG[PROXY_PORT]}" ]]; then
        if [[ ${INTERACTIVE_MODE} == true ]]; then
            while true; do
                read -r -p "Proxy/Remote Port (default 8080): " user_input
                proxy_port="${user_input:-"${DEFAULTS[PROXY_PORT]:-8080}"}"
                if validate_port "${proxy_port}"; then break; fi
            done
        else
            proxy_port="${DEFAULTS[PROXY_PORT]:-8080}"
        fi
        DEFAULTS[PROXY_PORT]="${proxy_port}"
    fi

    if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" || "${proxy_mode}" == "TRANSPARENT_LOCAL" || "${proxy_mode}" == "REMOTE_DNAT" ]]; then
         if [[ -z "${ARG[PROXY_USER]}" ]]; then
             if [[ ${INTERACTIVE_MODE} == true ]]; then
                read -r -p "Proxy Username (optional): " user_input
                DEFAULTS[PROXY_USER]="${user_input:-"${DEFAULTS[PROXY_USER]}"}"
             fi
         fi

         if [[ -n "${DEFAULTS[PROXY_USER]}" && -z "${ARG[PROXY_PASS]}" ]]; then
             if [[ ${INTERACTIVE_MODE} == true ]]; then
                read -s -r -p "Proxy Password: " user_input
                echo
                DEFAULTS[PROXY_PASS]="${user_input:-"${DEFAULTS[PROXY_PASS]}"}"
             fi
         fi
    fi

    if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" && ${INTERACTIVE_MODE} == true ]]; then
         if [[ -z "${ARG[PROXY_TYPE]}" ]]; then
             local type_choice
             type_choice=$(select_from_list "Upstream Proxy Type:" "HTTP" "SOCKS4" "SOCKS5")
             DEFAULTS[PROXY_TYPE]="${type_choice,,}"
         fi
    fi

    if [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]]; then
        if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" || "${proxy_mode}" == "REMOTE_DNAT" ]]; then
                [[ -n "${DEFAULTS[PROXY_HOST]}" ]] || error "Proxy host is required for ${proxy_mode} (use --proxy-host)"
        fi
        
        [[ -n "${DEFAULTS[PROXY_PORT]}" ]] || error "Proxy port is required (use --proxy-port)"

        if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" ]]; then
            [[ -n "${DEFAULTS[PROXY_TYPE]}" ]] || error "Proxy type is required for Upstream Proxy (use --proxy-type)"
        fi
    fi

    log "Proxy configured. Mode: ${proxy_mode}"
    setup_proxy
}

setup_proxy() {
    [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]] || return 0
    local mode="${DEFAULTS[PROXY_MODE]}"

    case "${mode}" in
        "TRANSPARENT_LOCAL")
            setup_local_transparent_proxy
            ;;
        "TRANSPARENT_UPSTREAM")
            setup_redsocks_upstream
            ;;
        "REMOTE_DNAT")
            setup_remote_dnat
            ;;
        *)
            # Default to local transparent proxy
            setup_local_transparent_proxy
            ;;
    esac
}

setup_local_transparent_proxy() {
    local port="${DEFAULTS[PROXY_PORT]:-8080}"
    log "Setting up Local Transparent Proxy on port ${port}..."
    sysctl -qw net.ipv4.ip_forward=1
    
    # Redirect HTTP/HTTPS to local proxy port
    IPTABLES_RULES+=(
        "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 80 -j REDIRECT --to-port ${port}"
        "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 443 -j REDIRECT --to-port ${port}"
    )

    log "Transparent proxy redirection applied. Please ensure your proxy tool is listening on port ${port}."
    return 0
}

setup_remote_dnat() {
    local proxy_ip="${DEFAULTS[PROXY_HOST]}"
    local proxy_port="${DEFAULTS[PROXY_PORT]}"
    
    if [[ -z "${proxy_ip}" || -z "${proxy_port}" ]]; then
        error "Remote Host/Port required for Remote DNAT"
    fi
    
    log "Setting up Remote Forwarding (DNAT) to ${proxy_ip}:${proxy_port}..."
    IPTABLES_RULES+=(
        "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 80  -j DNAT --to-destination ${proxy_ip}:${proxy_port}"
        "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 443 -j DNAT --to-destination ${proxy_ip}:${proxy_port}"
    )
}

setup_redsocks_upstream() {
    local proxy_host="${DEFAULTS[PROXY_HOST]}"
    local proxy_port="${DEFAULTS[PROXY_PORT]}"
    local proxy_type="${DEFAULTS[PROXY_TYPE]}"
    local proxy_user="${DEFAULTS[PROXY_USER]:-}"
    local proxy_pass="${DEFAULTS[PROXY_PASS]:-}"

    if ! command -v redsocks >/dev/null; then
        warn "redsocks not installed. Cannot setup upstream proxying."
        return 1
    fi
    
    local redsocks_type="http-connect"
    case "${proxy_type}" in
        http)   redsocks_type="http-connect" ;;
        socks4) redsocks_type="socks4" ;;
        socks5) redsocks_type="socks5" ;;
    esac

    log "Setting up Upstream Proxy via redsocks (${proxy_type}://${proxy_host}:${proxy_port})..."
    local redsocks_conf="${REDSOCKS_CONF}"
    local redsocks_pid_file="${TMP_DIR}/redsocks.pid"

    cat > "${redsocks_conf}" << EOF
base {
    log_debug = off;
    log_info = on;
    log = "file:${REDSOCKS_LOG}";
    daemon = on;
    pidfile = "${redsocks_pid_file}";
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = ${proxy_host};
    port = ${proxy_port};
    type = ${redsocks_type};
EOF
    [[ -n "${proxy_user}" ]] && {
        echo "    login = ${proxy_user};" >> "${redsocks_conf}"
        echo "    password = ${proxy_pass};" >> "${redsocks_conf}"
    }
    echo "}" >> "${redsocks_conf}"

    if ! redsocks -c "${redsocks_conf}"; then
        warn "Failed to start redsocks"
        return 1
    fi

    sleep 1
    if [[ -f "${redsocks_pid_file}" ]]; then
        local redsocks_pid
        redsocks_pid=$(< "${redsocks_pid_file}")
        PIDS+=("${redsocks_pid}")
    else
        warn "redsocks PID file not found; process tracking may be inaccurate"
        # Fallback to pgrep only if pidfile absent
        redsocks_pid=$(pgrep -n redsocks)
        [[ -n "${redsocks_pid}" ]] && PIDS+=("${redsocks_pid}")
    fi

    if [[ -n "${redsocks_pid}" ]]; then
        log "Redsocks started with PID: ${redsocks_pid}"    
        IPTABLES_RULES+=(
            "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 80 -j REDIRECT --to-port 12345"
            "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 443 -j REDIRECT --to-port 12345"
        )
    fi
}
