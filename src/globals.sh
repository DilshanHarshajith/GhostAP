#!/bin/bash

# Define Project Root
# SCRIPT_DIR will be the parent directory of this file (src/..) which is the project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONFIG_DIR="${SCRIPT_DIR}/Config"
SETUP_DIR="${SCRIPT_DIR}/Setups"
LOG_DIR="${SCRIPT_DIR}/Logs"
OUT_DIR="${SCRIPT_DIR}/Output"
TMP_DIR="${SCRIPT_DIR}/Temp"
LOG_FILE="${LOG_DIR}/GhostAP.log"

# Configuration Files
declare -g HOSTAPD_CONF="${CONFIG_DIR}/hostapd.conf"
declare -g DNSMASQ_CONF="${CONFIG_DIR}/dnsmasq.conf"
declare -g REDSOCKS_CONF="${CONFIG_DIR}/redsocks.conf"

# Log Files
declare -g HOSTAPD_LOG="${LOG_DIR}/hostapd.log"
declare -g DNSMASQ_LOG="${LOG_DIR}/dnsmasq.log"
declare -g REDSOCKS_LOG="${LOG_DIR}/redsocks.log"
declare -g MITMPROXY_LOG="${LOG_DIR}/mitmproxy.log"
declare -g TSHARK_LOG="${LOG_DIR}/tshark.log"
declare -g SSLKEYLOGFILE="${LOG_DIR}/sslkey.log"

# PID Files
declare -g DNSMASQ_PID_FILE="${TMP_DIR}/dnsmasq.pid"


DIRS=(
    "${CONFIG_DIR}"
    "${LOG_DIR}"
    "${OUT_DIR}"
    "${TMP_DIR}"
)

# Initialize directories
for dir in "${DIRS[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}" || {
            echo "Failed to create directory: ${dir}" >&2
            exit 1
        }
        chmod -R 755 "${dir}" || {
            echo "Failed to set permissions for directory: ${dir}" >&2
            exit 1
        }
    fi
done

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

    [PROXY_ENABLED]=false
    [PROXY_HOST]=""
    [PROXY_PORT]=""
    [PROXY_BACKEND]=""
    [PROXY_MODE]=""
    [START_MITM_AUTO]=true
    [MITM_LOCATION]=""
    [PROXY_TYPE]=""
    [PROXY_USER]=""
    [PROXY_PASS]=""
    [CLONE]=false
    [CLONE_SSID]=""
    [CLONE_SSID]=""
    [SPOOF_DOMAINS]=""
    [SPOOF_TARGET_IP]=""
    [BLOCK_DOH]=false
)

declare -A ARG

declare -g INTERACTIVE_MODE=false
declare -g SAVE_CONFIG=false
declare -g CONFIG_FILE=""
declare -g INTERFACE="${DEFAULTS[INTERFACE]}"
declare -g SOURCE_INTERFACE="${DEFAULTS[SOURCE_INTERFACE]}"
declare -g SUBNET_OCT="${DEFAULTS[SUBNET]}"
declare -g SPOOF_DOMAINS=""

# Packet Capture Globals
declare -g CAPTURE_FILE=""
declare -g TMP_CAPTURE=""
declare -g TSHARK_PID=""

declare -g -a PIDS=()
declare -g -a IPTABLES_RULES=()
declare -g -a APPLIED_RULES=()

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
