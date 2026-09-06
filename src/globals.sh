#!/bin/bash

# Detect real user home
if [[ -n "$SUDO_USER" ]]; then
    # If running under sudo, get the real user's home
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    USER_HOME="$HOME"
fi

# APP_USER_DIR: per-user folder in home (~) for configs, logs, outputs, and temp files
APP_USER_DIR="${USER_HOME}/GhostAP"

# WORKING_DIR: current working directory
WORKING_DIR="$(pwd)"

CONFIG_DIR="${APP_USER_DIR}/Config"
SETUP_DIR="${APP_USER_DIR}/Setups"
LOG_DIR="${APP_USER_DIR}/Logs"
OUT_DIR="${WORKING_DIR}"
TMP_DIR="${APP_USER_DIR}/Temp"
LOG_FILE="${LOG_DIR}/GhostAP.log"

# Configuration Files
declare -g HOSTAPD_CONF="${CONFIG_DIR}/hostapd.conf"
declare -g DNSMASQ_CONF="${CONFIG_DIR}/dnsmasq.conf"
declare -g REDSOCKS_CONF="${CONFIG_DIR}/redsocks.conf"

# Log Files
declare -g HOSTAPD_LOG="${LOG_DIR}/hostapd.log"
declare -g DNSMASQ_LOG="${LOG_DIR}/dnsmasq.log"
declare -g REDSOCKS_LOG="${LOG_DIR}/redsocks.log"
declare -g TSHARK_LOG="${LOG_DIR}/tshark.log"
declare -g AIRODUMP_LOG="${LOG_DIR}/airodump.log"

# SSLKeylog file
declare -g SSLKEYLOGFILE="${OUT_DIR}/sslkey.log"

# PID Files
declare -g DNSMASQ_PID_FILE="${TMP_DIR}/dnsmasq.pid"


DIRS=(
    "${CONFIG_DIR}"
    "${SETUP_DIR}"
    "${LOG_DIR}"
    "${OUT_DIR}"
    "${TMP_DIR}"
)

# Initialize directories
if [[ ${EUID} -eq 0 ]]; then
    for dir in "${DIRS[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            mkdir -p "${dir}" || { echo "Failed to create directory: ${dir}" >&2; exit 1; }
        fi
        [[ -n "$SUDO_USER" ]] && { chown -R "$SUDO_USER:$SUDO_USER" "${dir}" || { echo "Failed to set ownership for directory: ${dir}" >&2; exit 1; } }
        chmod g+s "${dir}" || { echo "Failed to set sticky bit for directory: ${dir}" >&2; exit 1; }
        chmod -R 775 "${dir}" || { echo "Failed to set permissions for directory: ${dir}" >&2; exit 1; }
    done
fi

declare -A DEFAULTS=(
    [INTERFACE]=""
    [SOURCE_INTERFACE]=""
    [SSID]="WiFi_AP"
    [CHANNEL]="6"
    [SUBNET]="10"
    [DNS]="8.8.8.8"
    [SECURITY]="open"
    [PASSWORD]=""
    [INTERNET_SHARING]=false
    [DNS_SPOOFING]=false
    [PACKET_CAPTURE]=false
    [CAPTURE_FILE]="${OUT_DIR}/capture-$(date +%Y%m%d-%H%M%S).pcap"

    [VPN_ROUTING]=false
    [VPN_INTERFACE]=""
    [VPN_CONFIG]=""
    [VPN_CREDS]=""

    [PROXY_ENABLED]=false
    [PROXY_HOST]=""
    [PROXY_PORT]=""
    [PROXY_MODE]=""
    [PROXY_TYPE]=""
    [PROXY_USER]=""
    [PROXY_PASS]=""
    [CLONE]=false
    [CLONE_SSID]=""
    [SPOOF_DOMAINS]=""
    [SPOOF_TARGET_IP]=""
    [BLOCK_DOH]=false
    [MAC]=""

    [CAPTIVE_PORTAL]=false
    [CAPTIVE_PORT]="8880"
    [CAPTIVE_TEMPLATE]=""

    # Ethernet AP mode — use an ethernet interface instead of hostapd/WiFi
    [ETHERNET_MODE]=false
)

declare -A ARG

declare -g INTERACTIVE_MODE=false
declare -g SAVE_CONFIG=false
declare -g CONFIG_FILE="${SETUP_DIR}/default.conf"

# --scan-aps: one-shot standalone AP survey, not a saved config setting
declare -g SCAN_APS_ONLY=false
declare -g SCAN_APS_DURATION=15

# Connected-client monitor (see src/monitor.sh). These are runtime knobs,
# not saved-config settings — they describe how the live client dashboard
# behaves while the AP is running.
# Refresh cadence for the live client dashboard (seconds). 2s keeps signal
# freshness without the fork cost of scanning every second.
declare -g MONITOR_INTERVAL=2
# Consecutive ticks a client can vanish from the radio + ARP before it is
# declared gone. Guards against flapping on transient hostapd/ARP hiccups.
declare -g MON_OFFLINE_THRESHOLD=3

# Radio source currently in use for station data: "hostapd" | "iw" | "".
# Set once by monitor.sh; not a knob.
declare -g MON_RADIO_SOURCE=""

# Snapshot maps, rebuilt every tick. Keyed by lowercase colon MAC.
declare -g -A MON_STA=()        # mac -> "signal|connected_time|rx|tx"   (from hostapd/iw)
declare -g -A MON_LEASE=()      # mac -> "ip|hostname"                    (from dnsmasq leases)
declare -g -A MON_IP2MAC=()     # ip  -> mac                              (reverse lease lookup)
declare -g -A MON_NEIGH=()      # ip  -> "state"                          (from ip neigh)
declare -g -A MON_NEIGH_MAC=()  # ip  -> mac

# Persistent per-client state across ticks: mac -> "ip|hostname|signal|connected_time|rx|tx|status"
declare -g -A MONITOR_CLIENTS=()
# Consecutive miss counters per mac (grace window for LEAVING).
declare -g -A MON_ARP_MISSES=()
# MACs seen at least once, so joins can be told apart from first render.
declare -g -A MON_SEEN_MACS=()

# Ring buffer of recent join/leave events rendered under the live table.
declare -g -a MONITOR_EVENTS=()
declare -g MON_SEEN_MACS_COUNT=0

# Lines written by the last monitor render (for in-place tput redraw).
declare -g MONITOR_RENDER_LINES=0

# Packet Capture Globals
declare -g CAPTURE_FILE="${DEFAULTS[CAPTURE_FILE]}"
declare -g TMP_CAPTURE=""
declare -g TSHARK_PID=""

declare -g -a PIDS=()
declare -g -a IPTABLES_RULES=()
declare -g -a APPLIED_RULES=()
declare -g ORIGINAL_IP_FORWARD=""

# Known DNS-over-HTTPS (DoH) provider IPs
declare -g -a DOH_PROVIDERS=(
    "1.1.1.1"           # Cloudflare
    "1.0.0.1"           # Cloudflare
    "8.8.8.8"           # Google
    "8.8.4.4"           # Google
    "9.9.9.9"           # Quad9
    "149.112.112.112"   # Quad9
    "208.67.222.222"    # OpenDNS
    "208.67.220.220"    # OpenDNS
)