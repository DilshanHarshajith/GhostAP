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
    echo "Interface: ${DEFAULTS[INTERFACE]}"
    echo "SSID: ${DEFAULTS[SSID]}"
    echo "Channel: ${DEFAULTS[CHANNEL]}"
    echo "Security: ${DEFAULTS[SECURITY]}"
    echo "IP Address: 192.168.${DEFAULTS[SUBNET]}.1"
    echo "DHCP Range: 192.168.${DEFAULTS[SUBNET]}.10-250"
    echo "DNS Server: ${DEFAULTS[DNS]}"
    echo "Internet Sharing(From): ${DEFAULTS[SOURCE_INTERFACE]:-Disabled}"
    if [[ "${DEFAULTS[VPN_ROUTING]}" == true ]]; then
        echo "VPN Routing: Enabled (${DEFAULTS[VPN_INTERFACE]:-Pending}) - Config: ${DEFAULTS[VPN_CONFIG]:-None}"
    else
        echo "VPN Routing: Disabled"
    fi
    echo "DNS Spoofing: ${DEFAULTS[DNS_SPOOFING]}"
    echo "Packet Capture: ${DEFAULTS[PACKET_CAPTURE]}"
    echo "Proxy Enabled: ${DEFAULTS[PROXY_ENABLED]}"
    [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]] && echo "Proxy: ${DEFAULTS[PROXY_TYPE]:-http}://${DEFAULTS[PROXY_HOST]:-127.0.0.1}:${DEFAULTS[PROXY_PORT]} (Mode: ${DEFAULTS[PROXY_MODE]})"
    [[ "${DEFAULTS[VPN_ROUTING]}" == true ]] && echo "VPN Config: ${DEFAULTS[VPN_CONFIG]:-None} | VPN Interface: ${DEFAULTS[VPN_INTERFACE]:-Pending} | VPN Credentials: ${DEFAULTS[VPN_CREDS]:-None}"
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
    [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]] && echo "View captures: ls -la \"${DEFAULTS[CAPTURE_FILE]}\""
}

show_usage() {
    cat << 'EOF'
GhostAP - Wireless Access Point Creator

Usage: sudo $0 [OPTIONS]

Basic Options:
  --int, --interactive          Start in interactive mode (default: auto-detect)
  --config FILE                 Load configuration from file
  --save NAME                   Save current configuration to file with specified name
  --help, -h                    Show this help message

Interface Options:
  -i, --interface IFACE         Wireless interface to use
  -si, --source-interface IFACE Source interface for internet sharing
  -m, --mac MAC                 MAC address to use (BSSID)

Network Options:
  -s, --ssid SSID               Network name (SSID)
  -c, --channel CHANNEL         WiFi channel (1-14)
  --security TYPE               Security type (open/wpa2/wpa3)
  --password PASSWORD           WiFi password (for WPA2/WPA3)
  --subnet OCTET                Subnet third octet (0-255)
  --dns IP                      DNS server IP address

Feature Options:
  --internet                    Enable internet sharing
  --capture [FILE]              Enable packet capture (optional output path)
  --clone [SSID]                Clone an existing AP by SSID
  --spoof [DOMAINS]             Enable DNS spoofing
                                Domains format: domain.com=1.2.3.4|domain2.com=10.0.0.1
  --spoof-target IP             Default target IP for domains without explicit IP
  --block-doh                   Block DNS-over-HTTPS to enforce DNS spoofing

VPN Options:
  --vpn [FILE]                  Enable VPN routing; optionally provide a config file
                                (.ovpn for OpenVPN, .conf for WireGuard)
  --vpn-interface IFACE         Use an already-running VPN interface
  --vpn-creds USER:PASS         Credentials for OpenVPN configs that require auth-user-pass

Proxy Options:
  --local-proxy                 Redirect AP traffic to a local interceptor (port 8080)
                                Run mitmproxy or Burp Suite on that port
  --remote-proxy                DNAT AP traffic to a remote host (requires --proxy-host/port)
  --proxy                       Forward AP traffic via redsocks to an upstream proxy
  --proxy-host HOST             Proxy server host/IP
  --proxy-port PORT             Proxy server port (default: 8080)
  --proxy-type TYPE             Upstream proxy type: http / socks4 / socks5
  --proxy-user USER             Proxy username (optional)
  --proxy-pass PASS             Proxy password (optional)

Examples:
  # Basic open access point
  sudo $0 -i wlan0 -s "OpenAP" -c 6 --security open

  # Secure WPA2 access point with internet sharing
  sudo $0 -i wlan0 -s "MyAP" -c 6 --security wpa2 --password "pass1234" --internet -si eth0

  # Access point with packet capture
  sudo $0 -i wlan0 -s "CaptureAP" --capture capture.pcap

  # Access point with DNS spoofing and DoH blocking
  sudo $0 -s "SpoofAP" --spoof "example.com=192.168.1.100|test.com=10.0.0.1" --block-doh

  # Clone an existing access point
  sudo $0 -i wlan0 --clone "TargetSSID"

  # VPN-routed access point (OpenVPN)
  sudo $0 -i wlan0 -s "VpnAP" --vpn client.ovpn --internet -si eth0

  # VPN-routed access point with credentials
  sudo $0 -i wlan0 -s "VpnAP" --vpn client.ovpn --vpn-creds "user:pass"

  # Local transparent interception (run Burp/mitmproxy on port 8080)
  sudo $0 -i wlan0 -s "InterceptAP" --local-proxy

  # Upstream proxy via redsocks
  sudo $0 -i wlan0 -s "ProxyAP" --proxy --proxy-host 10.0.0.5 --proxy-port 3128 --proxy-type http

  # Save and reload configuration
  sudo $0 -i wlan0 -s "MyAP" --security wpa2 --password "secret" --save myconfig
  sudo $0 --config myconfig

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