#!/bin/bash

# Proxy Modes:
# 1. TRANSPARENT_LOCAL (mitmproxy): Intercepts traffic locally on AP. Clients -> AP (8080) -> Internet
# 2. TRANSPARENT_UPSTREAM (redsocks): Intercepts traffic and forwards to an external proxy. Clients -> AP -> Redsocks -> External Proxy -> Internet
# 3. REMOTE_DNAT (iptables): Simple DNAT forwarding to an external IP (e.g., if external IP is running mitmproxy). Clients -> AP -> Destination (DNAT)

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
            "Local Transparent Proxy (Intercept with mitmproxy)" \
            "Upstream Proxy (Forward to external HTTP/SOCKS proxy via redsocks)" \
            "Remote Forwarding (Simple DNAT to external IP:Port)")
        
        case "${mode_choice}" in
            "Local Transparent Proxy"*) proxy_mode="TRANSPARENT_LOCAL" ;;
            "Upstream Proxy"*)          proxy_mode="TRANSPARENT_UPSTREAM" ;;
            "Remote Forwarding"*)       proxy_mode="REMOTE_DNAT" ;;
        esac
        DEFAULTS[PROXY_MODE]="${proxy_mode}"
    fi

    if [[ "${proxy_mode}" == "TRANSPARENT_LOCAL" && ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[START_MITM_AUTO]}" ]]; then
            read -r -p "Automatically start mitmproxy/mitmweb? (Y/n): " mitm_auto_start
            if [[ "${mitm_auto_start}" =~ ^[Nn]$ ]]; then
                DEFAULTS[START_MITM_AUTO]=false
            else
                DEFAULTS[START_MITM_AUTO]=true
            fi
        fi
    fi

    local backend_tool=""
    case "${proxy_mode}" in
        "TRANSPARENT_LOCAL")
            backend_tool="mitmproxy"
            ;;
        "TRANSPARENT_UPSTREAM")
            backend_tool="redsocks"
            ;;
        "REMOTE_DNAT")
            backend_tool="none" # Just iptables
            ;;
        *)
            # Fallback/Default if arguments were odd
            if [[ -n "${DEFAULTS[PROXY_BACKEND]}" ]]; then
                 # Logic for backwards compatibility or manual CLI args
                 if [[ "${DEFAULTS[PROXY_BACKEND]}" == "mitmproxy" ]]; then
                     if [[ "${DEFAULTS[MITM_LOCATION]}" == "REMOTE" ]]; then
                         proxy_mode="REMOTE_DNAT"
                     else
                         proxy_mode="TRANSPARENT_LOCAL"
                     fi
                 elif [[ "${DEFAULTS[PROXY_BACKEND]}" == "redsocks" ]]; then
                     proxy_mode="TRANSPARENT_UPSTREAM"
                 fi
            else
                proxy_mode="TRANSPARENT_LOCAL" # Default
            fi
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

        if [[ -z "${ARG[PROXY_PORT]}" ]]; then
             while true; do
                read -r -p "Proxy/Remote Port: " user_input
                proxy_port="${user_input:-"${DEFAULTS[PROXY_PORT]}"}"
                if validate_port "${proxy_port}"; then break; fi
            done
            DEFAULTS[PROXY_PORT]="${proxy_port}"
        fi
    fi

    if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" ]]; then
         if [[ -z "${ARG[PROXY_TYPE]}" ]]; then
             local type_choice
             type_choice=$(select_from_list "Upstream Proxy Type:" "HTTP" "SOCKS4" "SOCKS5")
             DEFAULTS[PROXY_TYPE]="${type_choice,,}"
         fi
         
         if [[ -z "${ARG[PROXY_USER]}" ]]; then
             read -r -p "Proxy Username (optional): " user_input
             DEFAULTS[PROXY_USER]="${user_input:-"${DEFAULTS[PROXY_USER]}"}"
         fi

         if [[ -n "${DEFAULTS[PROXY_USER]}" && -z "${ARG[PROXY_PASS]}" ]]; then
             read -s -r -p "Proxy Password: " user_input
             echo
             DEFAULTS[PROXY_PASS]="${user_input:-"${DEFAULTS[PROXY_PASS]}"}"
         fi
    else
        # Non-Interactive Mode Validation
        if [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]]; then
            if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" || "${proxy_mode}" == "REMOTE_DNAT" ]]; then
                 [[ -n "${DEFAULTS[PROXY_HOST]}" ]] || error "Proxy host is required for ${proxy_mode} (use --proxy-host)"
                 [[ -n "${DEFAULTS[PROXY_PORT]}" ]] || error "Proxy port is required for ${proxy_mode} (use --proxy-port)"
            fi
            
            if [[ "${proxy_mode}" == "TRANSPARENT_UPSTREAM" ]]; then
                [[ -n "${DEFAULTS[PROXY_TYPE]}" ]] || error "Proxy type is required for Upstream Proxy (use --proxy-type)"
            fi
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
            setup_mitmproxy_local
            ;;
        "TRANSPARENT_UPSTREAM")
            setup_redsocks_upstream
            ;;
        "REMOTE_DNAT")
            setup_remote_dnat
            ;;
        *)
            # Try to infer from legacy vars if MODE not set
            local backend="${DEFAULTS[PROXY_BACKEND]:-mitmproxy}"
            if [[ "${backend}" == "mitmproxy" ]]; then
                 if [[ "${DEFAULTS[MITM_LOCATION]}" == "REMOTE" ]]; then
                    setup_remote_dnat
                 else
                    setup_mitmproxy_local
                 fi
            elif [[ "${backend}" == "redsocks" ]]; then
                setup_redsocks_upstream
            fi
            ;;
    esac
}

setup_mitmproxy_local() {
    log "Setting up Local Transparent Proxy (mitmproxy)..."
    sysctl -qw net.ipv4.ip_forward=1
    
    # Redirect HTTP/HTTPS to mitmproxy (default 8080)
    # Note: mitmproxy must be running in transparent mode (usually on port 8080)
    IPTABLES_RULES+=(
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port 8080"
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 8080"
    )

    if [[ "${DEFAULTS[START_MITM_AUTO]}" == true ]]; then
        local mitm_tool=""
        if command -v mitmweb >/dev/null; then
            mitm_tool="mitmweb"
        elif command -v mitmdump >/dev/null; then
            mitm_tool="mitmdump"
        fi

        if [[ -n "${mitm_tool}" ]]; then
            log "Starting ${mitm_tool} in transparent mode..."
            local mitm_log="${MITMPROXY_LOG}"
            
            # Start mitmproxy tool in background
            # --mode transparent: ensure transparent proxying
            # --showhost: show Host header in flows
            # --listen-port 8080: match iptables redirect
            local mitm_cmd=("${mitm_tool}" "--mode" "transparent" "--showhost" "--listen-port" "8080")
            
            if [[ "${mitm_tool}" == "mitmweb" ]]; then
                mitm_cmd+=("--web-port" "8081")
                log "mitmweb UI will be available at http://127.0.0.1:8081"
            fi
            
            # Set SSLKEYLOGFILE for Wireshark decryption
            export SSLKEYLOGFILE="${SSLKEYLOGFILE}"
            
            "${mitm_cmd[@]}" > "${mitm_log}" 2>&1 &
            local mitm_pid=$!
            
            sleep 2
            if kill -0 "${mitm_pid}" 2>/dev/null; then
                # Verify mitmproxy is actually listening on port 8080
                local listen_check=0
                local max_attempts=5
                while [[ ${listen_check} -lt ${max_attempts} ]]; do
                    if ss -tlnp 2>/dev/null | grep -q ":8080" || netstat -tlnp 2>/dev/null | grep -q ":8080"; then
                        log "Verified: mitmproxy is listening on port 8080"
                        break
                    fi
                    sleep 1
                    ((listen_check++))
                done
                
                if [[ ${listen_check} -eq ${max_attempts} ]]; then
                    warn "mitmproxy started but may not be listening on port 8080"
                    warn "Check ${mitm_log} for details"
                fi
                
                PIDS+=("${mitm_pid}")
                log "${mitm_tool} started with PID: ${mitm_pid}"
                
                # Start HTTP server to serve certs and keys
                serve_mitm_cert
            else
                error "${mitm_tool} failed to start. Check ${mitm_log}"
            fi
        else
             warn "mitmweb/mitmdump not found. Please install 'mitmproxy' package."
        fi
    else
        log "Skipping automatic mitmproxy startup. Please run it manually on port 8080."
    fi

    return 0
}

serve_mitm_cert() {
    log "Setting up Certificate & Key Distribution..."
    
    local cert_dir="${HOME}/.mitmproxy"
    local serve_dir="${TMP_DIR}/cert_serve"
    local gateway_ip="192.168.${SUBNET_OCT}.1"
    local serve_port="9999"
    
    mkdir -p "${serve_dir}"
    
    # Wait for cert to be generated if it's new
    local max_retries=10
    local count=0
    while [[ ! -f "${cert_dir}/mitmproxy-ca-cert.pem" ]] && [[ $count -lt $max_retries ]]; do
        sleep 1
        ((count++))
    done
    
    if [[ -f "${cert_dir}/mitmproxy-ca-cert.pem" ]]; then
        cp "${cert_dir}/mitmproxy-ca-cert.pem" "${serve_dir}/"
        # Also copy as .crt for some devices
        cp "${cert_dir}/mitmproxy-ca-cert.pem" "${serve_dir}/mitmproxy-ca-cert.crt"
    else
        warn "Could not find mitmproxy-ca-cert.pem in ${cert_dir}"
    fi
    
    # Symlink the SSL Keylog file (it might not exist yet, which is fine)
    ln -sf "${SSLKEYLOGFILE}" "${serve_dir}/sslkey.log"
    
    # Create an index.html for easy navigation
    cat > "${serve_dir}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>GhostAP MITM Setup</title>
    <style>
        body { font-family: sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
        h1 { color: #333; }
        .card { border: 1px solid #ddd; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; background: #f9f9f9; }
        code { background: #eee; padding: 0.2rem 0.4rem; border-radius: 4px; }
        a { color: #0066cc; text-decoration: none; font-weight: bold; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>GhostAP MITM Setup</h1>
    
    <div class="card">
        <h2>1. Install CA Certificate</h2>
        <p>To intercept HTTPS traffic, you must install this certificate on your device and trust it as a Root CA.</p>
        <p><a href="mitmproxy-ca-cert.pem">Download Certificate (.pem)</a></p>
        <p><a href="mitmproxy-ca-cert.crt">Download Certificate (.crt)</a> - Try this if .pem doesn't work (e.g. Android)</p>
        
        <h3>Firefox Installation (IMPORTANT)</h3>
        <p><strong>Firefox uses its own certificate store</strong> and does NOT use system certificates. Follow these steps:</p>
        <ol>
            <li>Open Firefox and go to <code>about:preferences#privacy</code></li>
            <li>Scroll down to <strong>Security → Certificates</strong></li>
            <li>Click <strong>View Certificates</strong></li>
            <li>Go to the <strong>Authorities</strong> tab</li>
            <li>Click <strong>Import</strong> and select the downloaded certificate</li>
            <li>Check <strong>"Trust this CA to identify websites"</strong></li>
            <li>Click OK</li>
        </ol>
        <p><em>Note: You may need to restart Firefox after importing the certificate.</em></p>
        
        <h3>System-wide Installation (Linux)</h3>
        <pre>sudo cp mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates</pre>
        <p><em>Note: This will work for curl and most applications, but NOT Firefox.</em></p>
    </div>
    <!--
    <div class="card">
        <h2>2. Wireshark Decryption</h2>
        <p>To decrypt traffic in Wireshark:</p>
        <ol>
            <li>Download the keylog file: <a href="sslkey.log">sslkey.log</a></li>
            <li>In Wireshark, go to <strong>Edit &rarr; Preferences &rarr; Protocols &rarr; TLS</strong></li>
            <li>Set <strong>(Pre)-Master-Secret log filename</strong> to the downloaded file (or map it via network share).</li>
        </ol>
        <p><em>Note: You can also use <code>curl http://${gateway_ip}:${serve_port}/sslkey.log</code> to fetch it live.</em></p>
    </div>
    -->
</body>
</html>
EOF

    if command -v python3 >/dev/null; then
        (cd "${serve_dir}" && python3 -m http.server "${serve_port}") >/dev/null 2>&1 &
        local py_pid=$!
        PIDS+=("${py_pid}")
        
        log "Certificate Server Running."
        log "--> To install certs, visit: http://${gateway_ip}:${serve_port} on your device"
        #log "--> SSL Keylog available at: http://${gateway_ip}:${serve_port}/sslkey.log"
    else
        warn "python3 not found. Cannot start certificate server."
    fi
}

setup_remote_dnat() {
    local proxy_ip="${DEFAULTS[PROXY_HOST]}"
    local proxy_port="${DEFAULTS[PROXY_PORT]}"
    
    if [[ -z "${proxy_ip}" || -z "${proxy_port}" ]]; then
        error "Remote Host/Port required for Remote DNAT"
    fi
    
    log "Setting up Remote Forwarding (DNAT) to ${proxy_ip}:${proxy_port}..."
    IPTABLES_RULES+=(
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 80  -j DNAT --to-destination ${proxy_ip}:${proxy_port}"
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 443 -j DNAT --to-destination ${proxy_ip}:${proxy_port}"
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

     cat > "${redsocks_conf}" << EOF
base {
    log_debug = off;
    log_info = on;
    log = "file:${REDSOCKS_LOG}";
    daemon = on;
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
    local redsocks_pid
    redsocks_pid=$(pgrep redsocks | head -1)
    if [[ -n "${redsocks_pid}" ]]; then
        PIDS+=("${redsocks_pid}")
        log "Redsocks started with PID: ${redsocks_pid}"
    
        IPTABLES_RULES+=(
            "iptables -t nat -I OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 12345"
            "iptables -t nat -I OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 12345"
            "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port 12345"
            "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 12345"
        )
    fi
}
