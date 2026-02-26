#!/bin/bash

# Logging functions
log() { 
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] $*" >&2
    echo "[${timestamp}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

error() { 
    log "ERROR: $*"
    cleanup
    exit 1
}

warn() { log "WARNING: $*"; }

debug() {
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $*"
}

# Cleanup function
cleanup() {
    log "Starting cleanup process..."
    local cleanup_errors=0

    rm -rf "${TMP_DIR}"
    
    for pid in "${PIDS[@]}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            debug "Killing process ${pid}"
            if ! kill "${pid}" 2>/dev/null; then
                 # If SIGTERM fails, wait a bit then SIGKILL
                 sleep 1
                 if kill -0 "${pid}" 2>/dev/null; then
                     warn "Force killing process ${pid}"
                     kill -9 "${pid}" 2>/dev/null || ((cleanup_errors++))
                 fi
            fi
        fi
    done
    
    pkill -f "tshark.*${INTERFACE}" 2>/dev/null || true
    pkill -f "redsocks" 2>/dev/null || true
    
    # VPN Cleanup
    cleanup_vpn
    
    sync
    move_capture_file

    if [[ -n "${INTERFACE}" ]]; then
        ip link set "${INTERFACE}" down
        iw dev "${INTERFACE}" set type managed
        ip link set "${INTERFACE}" up
        nmcli device set "${INTERFACE}" managed yes 2>/dev/null || warn "Failed to disable NetworkManager for ${INTERFACE}"
    fi
    
    for ((i=${#APPLIED_RULES[@]}-1; i>=0; i--)); do
        debug "Removing iptables rule: ${APPLIED_RULES[i]}"
        eval "${APPLIED_RULES[i]}" 2>/dev/null || ((cleanup_errors++))
    done

    if command -v tc >/dev/null && [[ -n "${INTERFACE}" ]]; then
        tc qdisc del dev "${INTERFACE}" root 2>/dev/null || true
    fi
    
    if [[ ${EUID} -eq 0 ]]; then
        sysctl -qw net.ipv4.ip_forward=0
        sysctl -qw net.ipv4.conf.all.forwarding=0
        sysctl -qw net.ipv4.conf.all.send_redirects=1
        if [[ -n "${INTERFACE}" ]]; then
            sysctl -qw net.ipv4.conf."${INTERFACE}".accept_redirects=1
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        for i in {1..3}; do
            if systemctl restart NetworkManager 2>/dev/null; then
                break
            elif [[ ${i} -eq 3 ]]; then
                warn "Failed to restart NetworkManager after 3 attempts"
                ((cleanup_errors++))
            else
                sleep 1
            fi
        done
    fi
    
    if [[ ${cleanup_errors} -gt 0 ]]; then
        warn "Cleanup completed with ${cleanup_errors} errors"
    else
        log "Cleanup completed successfully"
    fi
}

# Validation functions
check_root() {
    [[ ${EUID} -eq 0 ]] || error "This script must be run as root (use sudo)"
}

check_dependencies() {
    local deps=(hostapd dnsmasq iw iptables ip)
    local optional_deps=(tshark redsocks python3)
    local missing=()
    local missing_optional=()
    
    for dep in "${deps[@]}"; do
        command -v "${dep}" >/dev/null || missing+=("${dep}")
    done
    
    for dep in "${optional_deps[@]}"; do
        command -v "${dep}" >/dev/null || missing_optional+=("${dep}")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}. Install with: apt install hostapd dnsmasq wireless-tools iptables iproute2"
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Missing optional dependencies: ${missing_optional[*]}. Some features may be unavailable."
        warn "Install with: apt install wireshark-common redsocks"
    fi
}

validate_ip() {
    local ip="$1"
    [[ ${ip} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        ((octet >= 0 && octet <= 255)) || return 1
    done
    return 0
}

validate_channel() {
    local channel="$1"
    [[ "${channel}" =~ ^[0-9]+$ ]] || return 1
    ((channel >= 1 && channel <= 14)) || return 1
    return 0
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1 && port <= 65535)) || return 1
    return 0
}

validate_mac() {
    local mac="$1"
    [[ "${mac}" =~ ^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$ ]] || return 1
    return 0
}



show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Network Configuration:
  -i, --interface <iface>    Wireless interface to use for AP
  -s, --ssid <name>          SSID (Network Name)
  -c, --channel <num>        Channel (1-14)
  --security <type>          Security type: open, wpa2, wpa3
  --password <pass>          Password for WPA2/WPA3 (8-63 chars)
  --subnet <octet>           Subnet octet (default: 10 -> 192.168.10.1)
  --dns <ip>                 Custom DNS server (default: 8.8.8.8)
  --internet                 Enable Internet Sharing (NAT)
  -si, --source-interface    Source interface for Internet (e.g., eth0)
  -m, --mac <mac>            Custom MAC address for AP (BSSID)


Features:
  --capture                  Enable Packet Capture (tshark)
  --spoof [domain]           Enable DNS Spoofing (optional: specify domain)
  --spoof-target <ip>        Default IP for spoofed domains (default: AP IP)
  --block-doh                Block DNS-over-HTTPS to enforce DNS spoofing
  --clone [ssid]             Clone an existing network (optional: specify SSID)

Proxy & Interception:
  --proxy-mode <mode>        Proxy Mode: TRANSPARENT_LOCAL, TRANSPARENT_UPSTREAM, REMOTE_DNAT
  
  Shortcut Proxy Flags:
  --local-proxy              Shortcut for --proxy-mode TRANSPARENT_LOCAL
  --remote-proxy             Shortcut for --proxy-mode REMOTE_DNAT
  --proxy                    Shortcut for --proxy-mode TRANSPARENT_UPSTREAM

  Proxy Options:
  --proxy-host <ip>          Upstream Proxy IP or Remote Host IP
  --proxy-port <port>        Proxy Port (default: 8080)
  --proxy-type <type>        Proxy Type: http, socks4, socks5
  --proxy-user <user>        Proxy Username
  --proxy-pass <pass>        Proxy Password

Global:
  --int, --interactive       Run in Interactive Mode
  --config <file>            Load configuration from file
  --save <name>              Save current configuration
  -h, --help                 Show this help message

Examples:
  $(basename "$0") -i wlan0 -s MyAP --internet
  $(basename "$0") --int
  $(basename "$0") -i wlan0 --local-proxy --spoof google.com
EOF
}

handle_signal() {
    local signal="$1"
    log "Received signal: ${signal}"
    cleanup
    exit 0
}
