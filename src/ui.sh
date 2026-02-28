#!/bin/bash

select_from_list() {
    local prompt="$1"
    local default_choice=""
    shift

    if [[ "$1" =~ ^[0-9]+$ ]]; then
        default_choice="$1"
        shift
    fi

    local options=("$@")
    local choice

    if [[ ${#options[@]} -eq 0 ]]; then
        error "No options provided to select from"
    fi

    echo "${prompt}" >&2
    for option_index in "${!options[@]}"; do
        echo "[$((option_index+1))] ${options[option_index]}" >&2
    done

    local prompt_str="Please select [1-${#options[@]}]"
    if [[ -n "${default_choice}" ]]; then
        prompt_str+=" [default: ${default_choice}]"
    fi
    prompt_str+=": "

    while true; do
        read -rp "${prompt_str}" choice

        if [[ -z "${choice}" && -n "${default_choice}" ]]; then
            choice="${default_choice}"
        fi

        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
            echo "${options[$((choice-1))]}"
            return
        fi

        echo "Invalid choice: '${choice}'. Please enter a number between 1 and ${#options[@]}" >&2
    done
}

show_status() {
   
    echo
    echo "=========================================="
    echo "              GhostAP Status               "
    echo "=========================================="
    echo "Interface: ${INTERFACE}"
    echo "SSID: ${DEFAULTS[SSID]}"
    echo "Channel: ${DEFAULTS[CHANNEL]}"
    echo "Security: ${DEFAULTS[SECURITY]}"
    echo "IP Address: 192.168.${SUBNET_OCT}.1"
    echo "DHCP Range: 192.168.${SUBNET_OCT}.10-250"
    echo "DNS Server: ${DEFAULTS[DNS]}"
    echo "Internet Sharing(From): ${SOURCE_INTERFACE:-Disabled}"
    echo "DNS Spoofing: ${DEFAULTS[DNS_SPOOFING]}"
    echo "Packet Capture: ${DEFAULTS[PACKET_CAPTURE]}"
    echo "Proxy Enabled: ${DEFAULTS[PROXY_ENABLED]}"
    if [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]]; then
        echo "Proxy: ${DEFAULTS[PROXY_TYPE]:-http}://${DEFAULTS[PROXY_HOST]:-127.0.0.1}:${DEFAULTS[PROXY_PORT]} (Mode: ${DEFAULTS[PROXY_MODE]})"
    fi
    echo "Running PIDs: ${PIDS[*]}"
    echo "Config Dir: ${CONFIG_DIR}"
    echo "Setup Dir: ${SETUP_DIR}"
    echo "Log Dir: ${LOG_DIR}"
    echo "Temp Dir: ${TMP_DIR}"
    echo "Out Dir: ${OUT_DIR}"
    echo "=========================================="
    
    echo
    echo "Access Point is running. Press Ctrl+C to stop."
    echo "Monitor logs: tail -f ${LOG_DIR}/GhostAP.log"
    if [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]]; then
        echo "View captures: ls -la \"${DEFAULTS[CAPTURE_FILE]}\""
    fi
}

show_usage() {
    cat << 'EOF'
GhostAP - Wireless Access Point Creator

Usage: sudo $0 [OPTIONS]

Basic Options:
  --int, --interactive         Start in interactive mode (default: auto-detect)
  --config FILE                Load configuration from file
  --save NAME                  Save current configuration to file with specified name
  --help, -h                   Show this help message

Interface Options:
  -i, --interface IFACE        Wireless interface to use
  -si, --source-interface IFACE Source interface for internet sharing
  -m, --mac MAC                MAC address to use (BSSID)

Network Options:
  -s, --ssid SSID             Network name (SSID)
  -c, --channel CHANNEL       WiFi channel (1-14)
  --security TYPE             Security type (open/wpa2/wpa3)
  -p, --password PASSWORD     WiFi password (for WPA2/WPA3)
  --subnet OCTET              Subnet third octet (0-255)
  --dns IP                    DNS server IP address

Feature Options:

  --internet                  Enable internet sharing
  --capture [FILE]            Enable packet capture
  --spoof [DOMAINS]           Enable DNS spoofing
                              Optional domains format: domain.com=192.168.1.1|domain2.com=237.84.2.178

Proxy Options:
  --local-proxy                Shortcut for --proxy-mode TRANSPARENT_LOCAL
  --remote-proxy               Shortcut for --proxy-mode REMOTE_DNAT
  --proxy                      Shortcut for --proxy-mode TRANSPARENT_UPSTREAM
  --proxy-mode MODE           Proxy mode (TRANSPARENT_LOCAL/TRANSPARENT_UPSTREAM/REMOTE_DNAT)
  --proxy-host HOST           Proxy server host/IP
  --proxy-port PORT           Proxy server port (default: 8080)
  --proxy-type TYPE           Proxy type (http/socks4/socks5)
  --proxy-user USER           Proxy username
  --proxy-pass PASS           Proxy password

Examples:
  # Basic secure access point
  sudo $0 -i wlan0 -s "MyAP" -c 6 --security wpa2 -p "password123"
  
  # Access point with internet sharing and packet capture
  sudo $0 --internet --capture "capture.pcap" -si eth0
  
  # Access point with proxy routing
  sudo $0 -i wlan0 --proxy --proxy-host 127.0.0.1 --proxy-port 8080 --proxy-type http
  

  # Access point with DNS spoofing
  sudo $0 -s "TestAP" --spoof "example.com=192.168.1.100|test.com=10.0.0.1"
  
  # Save configuration for later use
  sudo $0 -i wlan0 -s "MyAP" --security wpa2 -p "secret" --save myconfig
  
  # Local transparent interception
  sudo $0 --local-proxy -s "InterceptAP"
  
  # Full featured access point
  sudo $0 -i wlan0 -s "FullAP" -c 11 --security wpa3 -p "strongpass" \
         --internet -si eth0 --capture --dns 1.1.1.1 --subnet 20

For more information, visit: https://github.com/DilshanHarshajith/GhostAP
EOF
}

show_connected_clients() {
    local lease_file="${TMP_DIR}/dhcp.leases"
    
    echo
    echo "=========================================="
    echo "           Connected Devices              "
    echo "=========================================="
    
    if [[ ! -f "${lease_file}" ]]; then
        echo "Waiting for connections..."
        return
    fi
    
    # Check if file is empty
    if [[ ! -s "${lease_file}" ]]; then
        echo "No devices connected yet."
        return
    fi
    
    printf "%-20s %-15s %-20s\n" "MAC Address" "IP Address" "Hostname"
    echo "--------------------------------------------------------"
    
    while read -r line; do
        # dnsmasq lease format: time mac ip hostname client_id
        local mac=$(echo "$line" | awk '{print $2}')
        local ip=$(echo "$line" | awk '{print $3}')
        local hostname=$(echo "$line" | awk '{print $4}')
        
        if [[ "${hostname}" == "*" ]]; then
            hostname="Unknown"
        fi
        
        printf "%-20s %-15s %-20s\n" "${mac}" "${ip}" "${hostname}"
    done < "${lease_file}"
    echo "=========================================="
}
