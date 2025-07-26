#!/bin/bash
# GhostAP - A Bash script for creating a WiFi access point with various features

if ((BASH_VERSINFO[0] < 4)); then
    echo "This script requires Bash version 4.0 or newer." >&2
    echo "Your version: ${BASH_VERSION}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../Config"
LOG_DIR="${SCRIPT_DIR}/../Logs"
OUT_DIR="${SCRIPT_DIR}/../Output"
TMP_DIR="${SCRIPT_DIR}/../Temp"
LOG_FILE="${LOG_DIR}/GhostAP.log"

DIRS=(
    "${CONFIG_DIR}"
    "${LOG_DIR}"
    "${OUT_DIR}"
    "${TMP_DIR}"
)
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
    [MONITOR_MODE]=false
    [PROXY_ENABLED]=false
    [PROXY_HOST]=""
    [PROXY_PORT]=""
    [PROXY_BACKEND]=""
    [MITM_LOCATION]=""
    [PROXY_TYPE]=""
    [PROXY_USER]=""
    [PROXY_PASS]=""
    [CLONE]=false
    [CLONE_SSID]=""
)

declare -A ARG

declare -g INTERACTIVE_MODE=false
declare -g SAVE_CONFIG=false
declare -g CONFIG_FILE=""
declare -g INTERFACE="${DEFAULTS[INTERFACE]}"
declare -g SOURCE_INTERFACE="${DEFAULTS[SOURCE_INTERFACE]}"
declare -g SUBNET_OCT="${DEFAULTS[SUBNET]}"
declare -g SPOOF_DOMAINS=""
declare -g -a PIDS=()
declare -g -a IPTABLES_RULES=()
declare -g -a APPLIED_RULES=()

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

cleanup() {
    log "Starting cleanup process..."
    local cleanup_errors=0

    rm -rf "${TMP_DIR}"
    
    for pid in "${PIDS[@]}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            debug "Killing process ${pid}"
            if ! timeout 5 bash -c "kill '${pid}' && while kill -0 '${pid}' 2>/dev/null; do sleep 0.1; done"; then
                warn "Force killing process ${pid}"
                kill -9 "${pid}" 2>/dev/null || ((cleanup_errors++))
            fi
        fi
    done
    
    pkill -f "tshark.*${INTERFACE}" 2>/dev/null || true
    pkill -f "redsocks" 2>/dev/null || true

    sync
    if [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]]; then
        if [[ -s "${tmp_capture}" ]]; then
            log "Tshark process ${tshark_pid} ended, moving capture to ${capture_file}"
            mv "${tmp_capture}" "${capture_file}"
            log "Capture file moved to: ${capture_file}"
        elif [[ -f "${tmp_capture}" ]]; then
            warn "Capture file was empty, not saved."
            rm -f "${tmp_capture}"
        else
            log "No capture file to move."
        fi
    fi

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
    
    sysctl -qw net.ipv4.ip_forward=0
    sysctl -qw net.ipv4.conf.all.forwarding=0
    sysctl -qw net.ipv4.conf.all.send_redirects=1
    sysctl -qw net.ipv4.conf."${INTERFACE}".accept_redirects=1

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

check_root() {
    [[ ${EUID} -eq 0 ]] || error "This script must be run as root (use sudo)"
}

check_dependencies() {
    local deps=(hostapd dnsmasq iw ifconfig iptables ip)
    local optional_deps=(tshark redsocks)
    local missing=()
    local missing_optional=()
    
    for dep in "${deps[@]}"; do
        command -v "${dep}" >/dev/null || missing+=("${dep}")
    done
    
    for dep in "${optional_deps[@]}"; do
        command -v "${dep}" >/dev/null || missing_optional+=("${dep}")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}. Install with: apt install hostapd dnsmasq wireless-tools net-tools iptables iproute2"
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Missing optional dependencies: ${missing_optional[*]}. Some features may be unavailable."
        warn "Install with: apt install wireshark-common redsocks"
    fi
}

get_wireless_interfaces() {
    local interfaces=()
    
    if command -v iw >/dev/null; then
        mapfile -t interfaces < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | sort -u)
    fi
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        mapfile -t interfaces < <(awk 'NR>2 {gsub(/:/, "", $1); print $1}' /proc/net/wireless 2>/dev/null | sort -u)
    fi
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        mapfile -t interfaces < <(find /sys/class/net -maxdepth 1 \( -name 'wl*' -o -name 'wlan*' \) -print0 2>/dev/null | xargs -0 -r basename -a | sort -u)
    fi
    
    [[ ${#interfaces[@]} -gt 0 ]] || error "No wireless interfaces found"
    printf '%s\n' "${interfaces[@]}"
}

get_internet_interfaces() {
    local interfaces=()
    local test_host="8.8.8.8"
    local retry=3

    mapfile -t all_ifaces < <(ip -o link show up | awk -F': ' '!/lo/ {print $2}')

    for iface in "${all_ifaces[@]}"; do
        for i in $(seq 1 "${retry}"); do
            if ping -I "${iface}" -c 1 -W 1 "${test_host}" &>/dev/null; then
                interfaces+=("${iface}")
                break
            fi
            sleep 1
        done
    done

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${interfaces[@]}"
}

get_network_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '/^[0-9]+:/ && !/lo:/ {gsub(/@.*/, "", $2); print $2}' | grep -v "^$" | sort -u || true
}

get_wifi_ssids() {
  local interface=${1:-"${DEFAULTS[INTERFACE]}"}  # Default interface wlan0, can be overridden by argument
  local ssids=()
  
  # Scan for Wi-Fi networks and extract SSIDs
  while IFS= read -r line; do
    # Skip empty SSIDs
    [[ -n "$line" ]] && ssids+=("$line")
  done < <(sudo iwlist "$interface" scan | grep 'ESSID:' | sed -e 's/.*ESSID:"\(.*\)"/\1/')

  echo "${ssids[@]}"
}

get_ap_info() {
  local target_ssid="$1"
  local interface="${2:-wlan0}"

  sudo iwlist "$interface" scan | awk -v ssid="$target_ssid" '
    BEGIN {
      mac = ""; channel = ""; essid = "";
    }

    /Cell [0-9]+ - Address:/ {
      mac = $NF;
      channel = ""; essid = "";
    }

    /Channel:/ {
      channel = $2;
    }

    /Frequency:/ {
      match($0, /\(Channel ([0-9]+)\)/, arr);
      if (arr[1] != "") channel = arr[1];
    }

    /ESSID:/ {
      match($0, /ESSID:"(.*)"/, arr);
      essid = arr[1];
      if (essid == ssid && mac && channel) {
        # Use pipe as delimiter
        print essid "|" channel "|" mac;
      }
    }
  '
}

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
    for i in "${!options[@]}"; do
        echo "[$((i+1))] ${options[i]}" >&2
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
}

load_config() {
    [[ -f "${CONFIG_FILE}" ]] || return 0
    
    log "Loading configuration from ${CONFIG_FILE}"
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key}" ]] && continue
        
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        
        if [[ -v DEFAULTS[${key}] ]]; then
            DEFAULTS[${key}]="${value}"
            debug "Loaded config: ${key}=${value}"
        else
            warn "Unknown configuration key: '${key}' in ${CONFIG_FILE}"
        fi
    done < "${CONFIG_FILE}"
}

save_config() {
    [[ "${SAVE_CONFIG}" == true ]] || return 0
    log "Saving current configuration..."
    local config_file="${CONFIG_DIR}/${CONFIG_NAME:-default}.conf"
    log "Saving configuration to ${config_file}"
    
    cat > "${config_file}" << EOF

SSID="${DEFAULTS[SSID]}"
CHANNEL="${DEFAULTS[CHANNEL]}"
SUBNET="${DEFAULTS[SUBNET]}"
DNS="${DEFAULTS[DNS]}"
SECURITY="${DEFAULTS[SECURITY]}"
PASSWORD="${DEFAULTS[PASSWORD]}"
INTERNET_SHARING="${DEFAULTS[INTERNET_SHARING]}"
DNS_SPOOFING="${DEFAULTS[DNS_SPOOFING]}"
PACKET_CAPTURE="${DEFAULTS[PACKET_CAPTURE]}"
MONITOR_MODE="${DEFAULTS[MONITOR_MODE]}"
PROXY_ENABLED="${DEFAULTS[PROXY_ENABLED]}"
PROXY_HOST="${DEFAULTS[PROXY_HOST]}"
PROXY_PORT="${DEFAULTS[PROXY_PORT]}"
PROXY_TYPE="${DEFAULTS[PROXY_TYPE]}"
PROXY_USER="${DEFAULTS[PROXY_USER]}"
PROXY_PASS="${DEFAULTS[PROXY_PASS]}"
EOF
}

configure_interface() {
    log "Configuring wireless interface..."

    local interfaces
    mapfile -t interfaces < <(get_wireless_interfaces)

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[INTERFACE]}" ]]; then
            INTERFACE=$(select_from_list "Select wireless interface:" "${interfaces[@]}")
            DEFAULTS[INTERFACE]="${INTERFACE}"
            log "Selected interface: ${INTERFACE}"
        elif [[ -n "${ARG[INTERFACE]}" ]]; then
            INTERFACE="${DEFAULTS[INTERFACE]}"
            log "Using specified interface: ${INTERFACE}"
        else
            warn "No wireless interface specified, using default: ${DEFAULTS[INTERFACE]}"
            INTERFACE="${DEFAULTS[INTERFACE]}"
        fi
    else
        if [[ -n "${ARG[INTERFACE]}" ]]; then
            INTERFACE="${DEFAULTS[INTERFACE]}"
            log "Selected interface: ${INTERFACE}"
        else
            INTERFACE=$(get_wireless_interfaces | head -n 1)
            DEFAULTS[INTERFACE]="${INTERFACE}"
            [[ -n "${INTERFACE}" ]] || error "No wireless interface found"
            warn "No wireless interface specified, using default: ${DEFAULTS[INTERFACE]}"
        fi
    fi

    if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
        error "Interface ${INTERFACE} not found"
    fi

    if [[ ! -e "/sys/class/net/${INTERFACE}/wireless" ]]; then
        warn "Interface ${INTERFACE} may not be a wireless interface"
    fi
}

configure_hostapd() {
    log "Configuring hostapd..."
    
    local config_file="${CONFIG_DIR}/hostapd.conf"

    local ssid="${DEFAULTS[SSID]}"
    local channel="${DEFAULTS[CHANNEL]}"
    local security="${DEFAULTS[SECURITY]}"
    local password="${DEFAULTS[PASSWORD]}"
    
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ -z "${DEFAULTS[CLONE]}" ]]; then
            if [[ -z "${ARG[SSID]}" ]]; then
                read -r -p "SSID [${ssid}]: " input
                ssid="${input:-${ssid}}"
            fi

            if [[ -z "${ARG[CHANNEL]}" ]]; then
                while true; do
                    read -r -p "Channel [${channel}]: " input
                    channel="${input:-${channel}}"
                    if validate_channel "${channel}"; then
                        break
                    else
                        echo "Invalid channel. Please enter 1-14"
                    fi
                done
            fi

            if [[ -z "${ARG[SECURITY]}" ]]; then
                declare -A SECURITY_MAP=(
                    ["Open (no password)"]="open"
                    ["WPA2-PSK (password)"]="wpa2"
                    ["WPA3-SAE (WPA3)"]="wpa3"
                )
                sec_choice=$(select_from_list "Security type:" 1 "Open (no password)" "WPA2-PSK (password)" "WPA3-SAE (WPA3)")
                security="${SECURITY_MAP[${sec_choice}]}"
            fi

            if [[ -z "${ARG[PASSWORD]}" && "${security}" != "open" ]]; then
                while true; do
                    read -s -r -p "Password (8-63 characters): " password
                    echo
                    if [[ ${#password} -ge 8 && ${#password} -le 63 ]]; then
                        break
                    else
                        echo "Password must be 8-63 characters long"
                    fi
                done
            fi
            
            DEFAULTS[SSID]="${ssid}"
            DEFAULTS[CHANNEL]="${channel}"
            DEFAULTS[SECURITY]="${security}"
            DEFAULTS[PASSWORD]="${password}"
        fi
    fi
    
    if ! validate_channel "${DEFAULTS[CHANNEL]}"; then
        error "Invalid channel: ${DEFAULTS[CHANNEL]} (must be 1-14)"
    fi

    if [[ ! "${DEFAULTS[SECURITY]}" =~ ^(open|wpa2|wpa3)$ ]]; then
        error "Invalid security type: ${DEFAULTS[SECURITY]} (must be open/wpa2/wpa3)"
    fi

    if [[ "${DEFAULTS[SECURITY]}" != "open" && (${#DEFAULTS[PASSWORD]} -lt 8 || ${#DEFAULTS[PASSWORD]} -gt 63) ]]; then
        error "Invalid password length: must be 8-63 characters for WPA2/WPA3"
    fi

    if [[ "${DEFAULTS[SECURITY]}" == "open" ]]; then
        DEFAULTS[PASSWORD]=""
    fi

    DEFAULTS[SSID]="${ssid}"
    DEFAULTS[CHANNEL]="${channel}"
    DEFAULTS[SECURITY]="${security}"
    DEFAULTS[PASSWORD]="${password}"

    cat > "${config_file}" << EOF
interface=${INTERFACE}
driver=nl80211
ssid=${ssid}
channel=${channel}
hw_mode=g
ieee80211n=1
wmm_enabled=1
ht_capab=[HT40][SHORT-GI-20][DSSS_CCK-40]
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
country_code=US
ieee80211d=1
ieee80211h=1
EOF

    case "${security}" in
        "wpa2")
            cat >> "${config_file}" << EOF
wpa=2
wpa_passphrase=${password}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
            ;;
        "wpa3")
            cat >> "${config_file}" << EOF
wpa=3
wpa_key_mgmt=SAE
sae_password=${password}
rsn_pairwise=CCMP
ieee80211w=2
EOF
            ;;
        "open")
            ;;
    esac
    log "Hostapd configured: SSID='${ssid}', Channel=${channel}, Security=${security}"
}

configure_dhcp() {
    log "Configuring DHCP server..."
    
    local config_file="${CONFIG_DIR}/dnsmasq.conf"
    
    local dns="${DEFAULTS[DNS]}"
    local subnet_oct="${DEFAULTS[SUBNET]}"

    if [[ "${INTERACTIVE_MODE}" == true ]]; then

        if [[ -z "${ARG[DNS]}" ]]; then
            local dns_choice
            dns_choice=$(select_from_list "DNS server:" 1 \
                "Google (8.8.8.8)" \
                "Cloudflare (1.1.1.1)" \
                "OpenDNS (208.67.222.222)" \
                "Local (192.168.${subnet_oct}.1)" \
                "Custom")
            
            case "${dns_choice}" in
                "Google (8.8.8.8)") dns="8.8.8.8" ;;
                "Cloudflare (1.1.1.1)") dns="1.1.1.1" ;;
                "OpenDNS (208.67.222.222)") dns="208.67.222.222" ;;
                "Local (192.168.${subnet_oct}.1)") dns="192.168.${subnet_oct}.1" ;;
                "Custom") 
                    while true; do
                        read -r -p "DNS IP: " dns
                        if validate_ip "${dns}"; then
                            break
                        else
                            echo "Invalid IP address"
                        fi
                    done
                    ;;
            esac
        fi

        if [[ -z "${ARG[SUBNET]}" ]]; then
            while true; do
                read -r -p "Subnet (third octet) [${DEFAULTS[SUBNET]}]: " input
                subnet_oct="${input:-${DEFAULTS[SUBNET]}}"
                if [[ "${subnet_oct}" =~ ^[0-9]+$ ]] && ((subnet_oct >= 0 && subnet_oct <= 255)); then
                    break
                else
                    echo "Invalid subnet octet. Please enter 0-255"
                fi
            done
        fi
        
        DEFAULTS[SUBNET]="${subnet_oct}"
        DEFAULTS[DNS]="${dns}"
    fi
    
    if { ! [[ "${subnet_oct}" =~ ^[0-9]+$ ]] || ! ((subnet_oct >= 0 && subnet_oct <= 255)); }; then
        error "Invalid subnet octet: ${subnet_oct} (must be 0-255)"
    fi
    
    if ! validate_ip "${dns}"; then
        error "Invalid DNS IP address: ${dns}"
    fi
    
    SUBNET_OCT="${subnet_oct}"
    
    cat > "${config_file}" << EOF
interface=${INTERFACE}
bind-interfaces
dhcp-range=192.168.${SUBNET_OCT}.10,192.168.${SUBNET_OCT}.250,255.255.255.0,12h
dhcp-option=6,192.168.${SUBNET_OCT}.1
dhcp-option=3,192.168.${SUBNET_OCT}.1
dhcp-leasefile=${TMP_DIR}/dhcp.leases
dhcp-authoritative
no-hosts
log-queries
log-dhcp
server=${dns}
cache-size=1000
neg-ttl=60
domain-needed
bogus-priv
EOF
        
    log "DHCP configured: Range=192.168.${SUBNET_OCT}.10-250, DNS=${dns}"
}

configure_internet_sharing() {
    local interfaces

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[INTERNET_SHARING]}" ]]; then
            read -r -p "Enable internet sharing? (y/N): " enable
            if [[ "${enable}" =~ ^[Yy]$ ]]; then
                DEFAULTS[INTERNET_SHARING]=true
            elif [[ "${enable}" =~ ^[Nn]$ ]]; then
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

configure_monitor_mode() {
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ -z "${ARG[MONITOR_MODE]}" ]]; then
            read -r -p "Enable monitor mode? (y/N): " enable
            if [[ "${enable}" =~ ^[Yy]$ ]]; then
                DEFAULTS[MONITOR_MODE]=true
                log "Monitor Mode Enabled."
            elif [[ "${enable}" =~ ^[Nn]$ ]]; then
                DEFAULTS[MONITOR_MODE]=false
            else
                return
            fi
        fi
    fi

    if [[ "${DEFAULTS[MONITOR_MODE]}" == true ]]; then
        log "Configuring monitor mode on interface ${INTERFACE}..."      
        enable_monitor_mode "${INTERFACE}" "${DEFAULTS[CHANNEL]}"
    else
        log "Monitor mode disabled."
    fi
}

enable_monitor_mode(){
    local iface="${1:-${INTERFACE}}"
    local channel="${2:-${DEFAULTS[CHANNEL]}}"

    ip link set "${iface}" down
    iw dev "${iface}" set type monitor
    iw dev "${iface}" set channel "${channel}"
    ip link set "${iface}" up
}

configure_dns_spoof() {
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[DNS_SPOOFING]}" ]]; then
            read -r -p "Enable DNS spoofing? (y/N): " enable
            if [[ "${enable}" =~ ^[Yy]$ ]]; then  
                DEFAULTS[DNS_SPOOFING]=true
            elif [[ "${enable}" =~ ^[Nn]$ ]]; then
                DEFAULTS[DNS_SPOOFING]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[DNS_SPOOFING]}" == true ]] || return

    log "Configuring DNS spoofing..."

    if [[ -n "${ARG[SPOOF_DOMAINS]}" ]]; then
        IFS='|' read -ra entries <<< "$SPOOF_DOMAINS"
        for entry in "${entries[@]}"; do
            if [[ "${entry}" =~ ^[^=]+=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "address=/${entry/=//}" >> "${CONFIG_DIR}/dnsmasq.conf"
                log "Added DNS spoof: ${entry}"
            else
                warn "Invalid format for DNS spoofing entry: ${entry}. Use Format: domain.com=192.168.1.1"
            fi
        done
    else
        while read -r -p "Enter domains to spoof (format: domain.com=192.168.1.1), empty line to finish: " entry && [[ -n "${entry}" ]]; do
            if [[ "${entry}" =~ ^[^=]+=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "address=/${entry/=//}" >> "${CONFIG_DIR}/dnsmasq.conf"
                log "Added DNS spoof: ${entry}"
            else
                echo "Invalid format. Use: domain.com=192.168.1.1"
            fi
        done
    fi

    log "DNS Spoofing Enabled. (configure manually in dnsmasq.conf if needed)"
}

configure_packet_capture() {    
    if ! command -v tshark >/dev/null; then
        warn "tshark not installed, packet capture will be unavailable"
        return 1
    fi

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[PACKET_CAPTURE]}" ]]; then
            read -r -p "Enable packet capture? (y/N): " enable
            if [[ "${enable}" =~ ^[Yy]$ ]]; then
                DEFAULTS[PACKET_CAPTURE]=true
                log "Packet Capture Enabled."
            elif [[ "${enable}" =~ ^[Nn]$ ]]; then
                DEFAULTS[PACKET_CAPTURE]=false
            fi
        fi
    fi

    if [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]]; then
        log "Configuring packet capture..."
        enable_packet_capture
    else
        log "Packet capture disabled."
        return 0
    fi
}

enable_packet_capture(){
    if [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]] && command -v tshark >/dev/null; then
        log "Starting packet capture..."

        base_name="$(date +%Y%m%d-%H%M%S).pcap"
        tmp_capture="/tmp/${base_name}"
        capture_file="${OUT_DIR}/capture-${base_name}"

        capture_log="${LOG_DIR}/tshark.log"
        
        tshark -i "${INTERFACE}" -w "${tmp_capture}" \
            -f "not arp and not stp" >> "${capture_log}" 2>&1 &
        tshark_pid=$!
        PIDS+=("${tshark_pid}")
        log "Packet capture started: ${capture_file} (PID: ${tshark_pid})"
    fi
}

configure_proxy() {
    local proxy_host="${DEFAULTS[PROXY_HOST]}"
    local proxy_port="${DEFAULTS[PROXY_PORT]}"
    local proxy_type="${DEFAULTS[PROXY_TYPE]}"
    local proxy_backend="${DEFAULTS[PROXY_BACKEND]}"
    local proxy_user="${DEFAULTS[PROXY_USER]}"
    local proxy_pass="${DEFAULTS[PROXY_PASS]}"
    local mitm_location="${DEFAULTS[MITM_LOCATION]}"

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[PROXY_ENABLED]}" ]]; then
            read -r -p "Enable proxy routing? (y/N): " enable
            if [[ "${enable}" =~ ^[Yy]$ ]]; then
                DEFAULTS[PROXY_ENABLED]=true
            elif [[ "${enable}" =~ ^[Nn]$ ]]; then
                DEFAULTS[PROXY_ENABLED]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]] || return

    if [[ -z "${ARG[PROXY_BACKEND]}" ]]; then
        proxy_backend=$(select_from_list "Proxy backend:" 1 "mitmproxy" "redsocks")
        proxy_backend="${proxy_backend,,}"
        DEFAULTS[PROXY_BACKEND]="${proxy_backend}"
    fi

    if [[ "${proxy_backend}" == "redsocks" || ( "${proxy_backend}" == "mitmproxy" && "${mitm_location}" == "REMOTE" ) ]]; then
        if [[ -z "${ARG[PROXY_TYPE]}" ]]; then
            if [[ "${mitm_location}" == "LOCAL" ]]; then
                proxy_type="HTTP"
            else
                proxy_type=$(select_from_list "Proxy type:" 1 "HTTP" "SOCKS4" "SOCKS5")
                proxy_type="${proxy_type,,}"
                DEFAULTS[PROXY_TYPE]="${proxy_type}"
            fi
        fi

        if [[ -z "${ARG[PROXY_HOST]}" ]]; then
            local proxy_host=""
            while true; do
                read -r -p "Proxy host/IP: " input
                proxy_host="${input:-"${DEFAULTS[PROXY_HOST]}"}"
                if [[ -n "${proxy_host}" ]] && (validate_ip "${proxy_host}" || [[ "${proxy_host}" =~ ^[a-zA-Z0-9.-]+$ ]]); then
                    break
                else
                    echo "Invalid host/IP address"
                fi
            done
            DEFAULTS[PROXY_HOST]="${proxy_host}"
        fi

        if [[ -z "${ARG[PROXY_PORT]}" ]]; then
            local proxy_port=""
            while true; do
                read -r -p "Proxy port: " input
                proxy_port="${input:-"${DEFAULTS[PROXY_PORT]}"}"
                if validate_port "${proxy_port}"; then
                    break
                else
                    echo "Invalid port number (1-65535)"
                fi
            done
            DEFAULTS[PROXY_PORT]="${proxy_port}"
        fi

        if [[ -z "${ARG[PROXY_USER]}" ]]; then
            local proxy_user=""
            read -r -p "Proxy username (leave blank if none): " input
            proxy_user="${input:-"${DEFAULTS[PROXY_USER]}"}"
            DEFAULTS[PROXY_USER]="${proxy_user}"
        fi

        if [[ -n "${DEFAULTS[PROXY_USER]}" && -z "${ARG[PROXY_PASS]}" ]]; then
            local proxy_pass=""
            while true; do
                read -s -r -p "Proxy password: " input
                proxy_pass="${input:-${DEFAULTS[PROXY_PASS]}}"
                if [[ -n "${proxy_pass}" ]]; then
                    break
                else
                    echo "Proxy password cannot be empty"
                fi
            done
            DEFAULTS[PROXY_PASS]="${proxy_pass}"
        fi

        local ph="${DEFAULTS[PROXY_HOST]}"
        local pp="${DEFAULTS[PROXY_PORT]}"
        local pt="${DEFAULTS[PROXY_TYPE]}"
        if ! validate_ip "${ph}" && ! [[ "${ph}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            error "Invalid proxy host: ${ph}"
        fi

        if ! validate_port "${pp}"; then
            error "Invalid proxy port: ${pp}"
        fi

        if ! [[ "${pt}" =~ ^(http|socks4|socks5)$ ]]; then
            error "Invalid proxy type: ${pt} (must be http/socks4/socks5)"
        fi

        if [[ "${proxy_backend}" == "redsocks" ]]; then
            log "RedSocks Proxy configured: ${proxy_type}://${proxy_host}:${proxy_port}"
        else
            log "MITMProxy configured(Remote): ${proxy_type}://${proxy_user}:${proxy_pass}@${proxy_host}:${proxy_port}"
        fi

    elif [[ "${proxy_backend}" == "mitmproxy" && "${mitm_location}" == "LOCAL" ]]; then
        DEFAULTS[PROXY_TYPE]="http"
        log "MITMProxy configured(Local)"
    else
        error "Unknown proxy backend: ${proxy_backend}"
    fi

    if [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]]; then
        log "Proxy routing enabled with backend: ${proxy_backend}"
        setup_proxy
    else
        log "Proxy routing disabled"
    fi
}

setup_proxy() {
    [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]] || return 0
    local backend="${DEFAULTS[PROXY_BACKEND]:-mitmproxy}"

    case "${backend}" in
        mitmproxy)
            setup_mitmproxy
        ;;
        redsocks)
            setup_redsocks_proxy
        ;;
        *) 
            error "Unknown proxy backend: ${backend}"
        ;;
    esac
}

setup_mitmproxy() {
    if ! command -v mitmproxy >/dev/null; then
        warn "mitmproxy not installed, proxy routing unavailable"
        return 1
    fi

    sysctl -qw net.ipv4.ip_forward=1
    sysctl -qw net.ipv4.conf.all.forwarding=1
    sysctl -qw net.ipv4.conf.all.send_redirects=0
    sysctl -qw net.ipv4.conf."${INTERFACE}".accept_redirects=0

    local proxy_location="${DEFAULTS[MITM_LOCATION]}"
    
    if [[ "${proxy_location}" == "LOCAL" ]]; then
        log "Setting up mitmproxy for local interception..."
        IPTABLES_RULES+=(
            "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port 8080"
            "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 8080"
        )
    elif [[ "${proxy_location}" == "REMOTE" ]]; then
        log "Setting up mitmproxy for remote interception..."
        local proxy_ip="${DEFAULTS[PROXY_HOST]}"
        local proxy_port="${DEFAULTS[PROXY_PORT]}"
        IPTABLES_RULES+=(
            "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 80  -j DNAT --to-destination ${proxy_ip}:${proxy_port}"
            "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 443 -j DNAT --to-destination ${proxy_ip}:${proxy_port}"
        )
    fi
    return 0
}

setup_redsocks_proxy() {
    local proxy_host="${DEFAULTS[PROXY_HOST]}"
    local proxy_port="${DEFAULTS[PROXY_PORT]}"
    local proxy_type="${DEFAULTS[PROXY_TYPE]}"
    local proxy_user="${DEFAULTS[PROXY_USER]:-}"
    local proxy_pass="${DEFAULTS[PROXY_PASS]:-}"

    case "${proxy_type}" in
        http)   redsocks_type=3 ;;
        socks4) redsocks_type=1 ;;
        socks5) redsocks_type=2 ;;
        *)      redsocks_type=3 ;;
    esac

    if ! command -v redsocks >/dev/null; then
        warn "redsocks not installed, proxy routing unavailable"
        return 1
    fi

    log "Setting up redsocks proxy routing..."
    local redsocks_conf="${CONFIG_DIR}/redsocks.conf"

    cat > "${redsocks_conf}" << EOF
base {
    log_debug = off;
    log_info = on;
    log = "file:${LOG_DIR}/redsocks.log";
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
    fi

    IPTABLES_RULES+=(
        "iptables -t nat -I OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 12345"
        "iptables -t nat -I OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 12345"
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port 12345"
        "iptables -t nat -I PREROUTING -i ${INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 12345"
    )

    log "Proxy routing enabled via redsocks"
}

configure_clone(){
    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[CLONE]}" ]]; then
            read -r -p "Enable interface cloning? (y/N): " enable
            if [[ "${enable}" =~ ^[Yy]$ ]]; then
                DEFAULTS[CLONE]=true
                log "Interface cloning enabled."
            elif [[ "${enable}" =~ ^[Nn]$ ]]; then
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
    DEFAULTS[SSID]="$ssid"
    DEFAULTS[CHANNEL]="$channel"
    DEFAULTS[MAC]="$mac"

    log "Cloning interface ${INTERFACE} with SSID: ${DEFAULTS[SSID]}, Channel: ${DEFAULTS[CHANNEL]}, MAC: ${DEFAULTS[MAC]}"
}

start_services() {
    log "Starting services..."
    
    if command -v nmcli >/dev/null; then
        nmcli device set "${INTERFACE}" managed no 2>/dev/null || warn "Failed to disable NetworkManager for ${INTERFACE}"
    fi
    
    local retry_count=0
    while [[ ${retry_count} -lt 3 ]]; do
        ifconfig "${INTERFACE}" down 2>/dev/null || true
        sleep 1
        
        if ifconfig "${INTERFACE}" "192.168.${SUBNET_OCT}.1" netmask 255.255.255.0 up; then
            sleep 2
            if ifconfig "${INTERFACE}" | grep -q "192.168.${SUBNET_OCT}.1"; then
                break
            fi
        fi
        
        ((retry_count++))
        warn "Interface configuration attempt ${retry_count} failed, retrying..."
        sleep 2
    done
    
    if [[ ${retry_count} -eq 3 ]]; then
        error "Failed to configure interface ${INTERFACE} after 3 attempts"
    fi
    
    log "Interface ${INTERFACE} configured with IP 192.168.${SUBNET_OCT}.1"
    pkill -f "hostapd.*${CONFIG_DIR}/hostapd.conf" 2>/dev/null || true
    sleep 1
    for i in {1..5}; do
        if ! pgrep -f "hostapd.*${CONFIG_DIR}/hostapd.conf" >/dev/null; then
            break
        fi
        warn "Waiting for previous hostapd to exit..."
        sleep 1
    done

    log "Starting hostapd..."
    local hostapd_log="${LOG_DIR}/hostapd.log"
    
    if ! hostapd -B -f "${hostapd_log}" "${CONFIG_DIR}/hostapd.conf"; then
        error "Failed to start hostapd. Check ${hostapd_log} for details."
    fi
    
    sleep 3
    local hostapd_pid
    hostapd_pid=$(pgrep -f "hostapd.*${CONFIG_DIR}/hostapd.conf" | head -1)
    if [[ -n "${hostapd_pid}" ]]; then
        PIDS+=("${hostapd_pid}")
        log "Hostapd started with PID: ${hostapd_pid}"
    else
        error "Hostapd failed to start properly"
    fi
    
    log "Starting dnsmasq..."
    local dnsmasq_log="${LOG_DIR}/dnsmasq.log"
    
    if ! dnsmasq -C "${CONFIG_DIR}/dnsmasq.conf" --pid-file="${TMP_DIR}/dnsmasq.pid" --log-facility="${dnsmasq_log}"; then
        error "Failed to start dnsmasq"
    fi
    
    if [[ -f "${TMP_DIR}/dnsmasq.pid" ]]; then
        local dnsmasq_pid
        dnsmasq_pid=$(<"${TMP_DIR}/dnsmasq.pid")
        PIDS+=("${dnsmasq_pid}")
        log "Dnsmasq started with PID: ${dnsmasq_pid}"
    else
        warn "Could not find dnsmasq PID file"
    fi

    log "Applying iptables rules..."
    for rule in "${IPTABLES_RULES[@]}"; do
        if ! ${rule} 2>/dev/null; then
            warn "Failed to add iptables rule: ${rule}"
        else
            log "Added iptables rule: ${rule}"
            APPLIED_RULES+=("${rule/-I/-D}")
        fi
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
        echo "Proxy: ${DEFAULTS[PROXY_TYPE]}://${DEFAULTS[PROXY_HOST]}:${DEFAULTS[PROXY_PORT]}"
    fi
    echo "Running PIDs: ${PIDS[*]}"
    echo "Config Dir: ${CONFIG_DIR}"
    echo "Log Dir: ${LOG_DIR}"
    echo "Temp Dir: ${TMP_DIR}"
    echo "Out Dir: ${OUT_DIR}"
    echo "=========================================="
    
    echo
    echo "Access Point is running. Press Ctrl+C to stop."
    echo "Monitor logs: tail -f ${LOG_DIR}/GhostAP.log"
    if [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]]; then
        echo "View captures: ls -la ${OUT_DIR}/*.pcap"
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

Network Options:
  -s, --ssid SSID             Network name (SSID)
  -c, --channel CHANNEL       WiFi channel (1-14)
  --security TYPE             Security type (open/wpa2/wpa3)
  -p, --password PASSWORD     WiFi password (for WPA2/WPA3)
  --subnet OCTET              Subnet third octet (0-255)
  --dns IP                    DNS server IP address

Feature Options:
  --monitor                   Enable monitor mode
  --internet                  Enable internet sharing
  --capture                   Enable packet capture
  --spoof [DOMAINS]           Enable DNS spoofing
                              Optional domains format: domain.com=192.168.1.1|domain2.com=237.84.2.178

Proxy Options:
  --mitmlocal                 Set proxy backend to mitmproxy with LOCAL location
  --mitmremote                Set proxy backend to mitmproxy with REMOTE location
  --proxy                     Set proxy backend to redsocks
  --proxy-host HOST           Proxy server host/IP
  --proxy-port PORT           Proxy server port
  --proxy-type TYPE           Proxy type (http/socks4/socks5)
  --proxy-user USER           Proxy username
  --proxy-pass PASS           Proxy password

Examples:
  # Basic secure access point
  sudo $0 -i wlan0 -s "MyAP" -c 6 --security wpa2 -p "password123"
  
  # Access point with internet sharing and packet capture
  sudo $0 --internet --capture -si eth0
  
  # Access point with proxy routing
  sudo $0 -i wlan0 --proxy --proxy-host 127.0.0.1 --proxy-port 8080 --proxy-type http
  
  # Load configuration and enable monitor mode
  sudo $0 --config /path/to/config.conf --monitor
  
  # Access point with DNS spoofing
  sudo $0 -s "TestAP" --spoof "example.com=192.168.1.100|test.com=10.0.0.1"
  
  # Save configuration for later use
  sudo $0 -i wlan0 -s "MyAP" --security wpa2 -p "secret" --save myconfig
  
  # mitmproxy local interception
  sudo $0 --mitmlocal -s "InterceptAP"
  
  # Full featured access point
  sudo $0 -i wlan0 -s "FullAP" -c 11 --security wpa3 -p "strongpass" \
         --internet -si eth0 --capture --dns 1.1.1.1 --subnet 20

For more information, visit: https://github.com/example/GhostAP
EOF
}

handle_signal() {
    local signal="$1"
    log "Received signal: ${signal}"
    cleanup
    exit 0
}

main() {
    if [[ -z "${INTERACTIVE_MODE:-}" ]]; then
        [[ -t 0 ]] && INTERACTIVE_MODE=true || INTERACTIVE_MODE=false
    fi

    local arg_values_set=false
    for var in SSID CHANNEL SUBNET DNS SECURITY PASSWORD INTERNET_SHARING DNS_SPOOFING PACKET_CAPTURE MONITOR_MODE PROXY_ENABLED PROXY_HOST PROXY_PORT PROXY_TYPE PROXY_USER PROXY_PASS INTERFACE SOURCE_INTERFACE; do
        if [[ -n "${DEFAULTS[${var}]}" && "${DEFAULTS[${var}]}" != "${!var}" && "${DEFAULTS[${var}]}" != "" ]]; then
            arg_values_set=true
            break
        fi
    done
    if [[ "${INTERACTIVE_MODE}" == true && "${arg_values_set}" == true ]]; then
        echo "⚠️  Info: You are using both interactive mode and command-line arguments."
        echo "    Arguments you provide will be used as defaults and will not be prompted for."
        echo "    You will only be prompted for values you did not specify as arguments."
    fi

    local SAVE_CONFIG=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --int|--interactive)
                INTERACTIVE_MODE=true
                shift
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    error "No configuration file specified after --config"
                fi
                CONFIG_FILE="$2"
                [[ -f "${CONFIG_FILE}" ]] || error "Configuration file not found: ${CONFIG_FILE}"
                shift 2
                ;;
            --save)
                if [[ -z "${2:-}" ]]; then
                    error "No name file specified after --save"
                fi            
                CONFIG_NAME="$2"
                SAVE_CONFIG=true
                shift 2
                ;;
            -i|--interface)
                if [[ -z "${2:-}" ]]; then
                    error "No interface specified after $1"
                fi
                DEFAULTS[INTERFACE]="$2"
                ARG[INTERFACE]=1
                shift 2
                ;;
            -s|--ssid)
                if [[ -z "${2:-}" ]]; then
                    error "No SSID specified after $1"
                fi
                DEFAULTS[SSID]="$2"
                ARG[SSID]=1
                shift 2
                ;;
            -c|--channel)
                if [[ -z "${2:-}" ]]; then
                    error "No channel specified after $1"
                fi
                DEFAULTS[CHANNEL]="$2"
                ARG[CHANNEL]=1
                shift 2
                ;;
            --security)
                if [[ -z "${2:-}" ]]; then
                    error "No security type specified after $1"
                fi
                DEFAULTS[SECURITY]="$2"
                ARG[SECURITY]=1
                shift 2
                ;;
            --password)
                if [[ -z "${2:-}" ]]; then
                    error "No password specified after $1"
                fi
                DEFAULTS[PASSWORD]="$2"
                ARG[PASSWORD]=1
                shift 2
                ;;
            --subnet)
                if [[ -z "${2:-}" ]]; then
                    error "No subnet specified after $1"
                fi
                DEFAULTS[SUBNET]="$2"
                ARG[SUBNET]=1
                shift 2
                ;;
            --dns)
                if [[ -z "${2:-}" ]]; then
                    error "No DNS IP specified after $1"
                fi
                DEFAULTS[DNS]="$2"
                ARG[DNS]=1
                shift 2
                ;;
            --clone)
                if [[ -n "${2:-}" ]]; then
                    DEFAULTS[CLONE_SSID]="$2"
                    ARG[CLONE_SSID]=1
                    DEFAULTS[CLONE]="$2"
                    ARG[CLONE]=1
                    shift 2
                else
                    DEFAULTS[CLONE]="$2"
                    ARG[CLONE]=1
                    shift
                fi
                ;;
            --internet)
                DEFAULTS[INTERNET_SHARING]=true
                ARG[INTERNET_SHARING]=1
                shift
                ;;
            -si|--source-interface)
                if [[ -z "${2:-}" ]]; then
                    error "No source interface specified after $1"
                fi
                DEFAULTS[INTERNET_SHARING]=true
                ARG[INTERNET_SHARING]=1                
                DEFAULTS[SOURCE_INTERFACE]="$2"
                ARG[SOURCE_INTERFACE]=1
                shift 2
                ;;
            --capture)
                DEFAULTS[PACKET_CAPTURE]=true
                ARG[PACKET_CAPTURE]=1
                shift
                ;;
            --spoof)
                if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                    SPOOF_DOMAINS="$2"
                    ARG[SPOOF_DOMAINS]=1
                    shift 2
                else
                    shift
                fi
                DEFAULTS[DNS_SPOOFING]=true
                ARG[DNS_SPOOFING]=1
                ;;
            --monitor)
                DEFAULTS[MONITOR_MODE]=true
                ARG[MONITOR_MODE]=1
                shift
                ;;
            --mitmlocal)
                DEFAULTS[MITM_LOCATION]="LOCAL"
                DEFAULTS[PROXY_BACKEND]="mitmproxy"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_BACKEND]=1
                ARG[PROXY_ENABLED]=1
                shift
                ;;
            --mitmremote)
                DEFAULTS[MITM_LOCATION]="REMOTE"
                DEFAULTS[PROXY_BACKEND]="mitmproxy"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_BACKEND]=1
                ARG[PROXY_ENABLED]=1
                shift
                ;;
            --proxy)
                DEFAULTS[PROXY_BACKEND]="redsocks"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_BACKEND]=1
                ARG[PROXY_ENABLED]=1
                shift
                ;;
            --proxy-host)
                if [[ -z "${2:-}" ]]; then
                    error "No proxy host specified after $1"
                fi
                DEFAULTS[PROXY_HOST]="$2"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_HOST]=1
                ARG[PROXY_ENABLED]=1
                shift 2
                ;;
            --proxy-port)
                if [[ -z "${2:-}" ]]; then
                    error "No proxy port specified after $1"
                fi
                DEFAULTS[PROXY_PORT]="$2"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_PORT]=1
                ARG[PROXY_ENABLED]=1
                shift 2
                ;;
            --proxy-type)
                if [[ -z "${2:-}" ]]; then
                    error "No proxy type specified after $1"
                fi
                DEFAULTS[PROXY_TYPE]="$2"
                ARG[PROXY_TYPE]=1
                shift 2
                ;;
            --proxy-user)
                if [[ -z "${2:-}" ]]; then
                    error "No proxy user specified after $1"
                fi
                DEFAULTS[PROXY_USER]="$2"
                ARG[PROXY_USER]=1
                shift 2
                ;;
            --proxy-pass)
                if [[ -z "${2:-}" ]]; then
                    error "No proxy password specified after $1"
                fi
                DEFAULTS[PROXY_PASS]="$2"
                ARG[PROXY_PASS]=1
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
    
    trap 'handle_signal SIGINT' SIGINT
    trap 'handle_signal SIGTERM' SIGTERM
        
    check_root
    check_dependencies
    
    log "GhostAP starting..."
    log "PID: $$, User: $(whoami)"
    
    [[ -n "${CONFIG_FILE}" ]] && load_config

    configure_interface
    configure_clone
    configure_hostapd
    configure_dhcp

    configure_monitor_mode
    configure_internet_sharing
    configure_proxy
    configure_dns_spoof
    configure_packet_capture

    start_services
    
    save_config    
    
    show_status

    log "Entering main loop, waiting for signals..."
    while true; do
        sleep 10
        for pid in "${PIDS[@]}"; do
            if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
                warn "Process ${pid} died unexpectedly"
            fi
        done
    done
}

main "$@"