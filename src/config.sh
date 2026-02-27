#!/bin/bash

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
            # Priority: CLI arguments (ARG) > Config file (CONFIG_FILE) > Defaults
            if [[ -z "${ARG[${key}]}" ]]; then
                DEFAULTS[${key}]="${value}"
                debug "Loaded config from file: ${key}=${value}"
            else
                debug "Skipping config file value for ${key} (already set via CLI)"
            fi
        else
            warn "Unknown configuration key: '${key}' in ${CONFIG_FILE}"
        fi
    done < "${CONFIG_FILE}"
}

save_config() {
    local default_config_name=$(basename "${CONFIG_FILE}" .conf)
    if [[ "${SAVE_CONFIG}" != true && "${INTERACTIVE_MODE}" = true ]]; then
        read -r -p "Save configuration? [y/N]: " save
        if [[ "${save}" =~ ^[Yy]$ ]]; then
            SAVE_CONFIG=true
            read -r -p "Enter configuration name [default: ${default_config_name}]: " CONFIG_NAME
        fi
    fi
 
    [[ "${SAVE_CONFIG}" == true ]] || return 0
    log "Saving current configuration..."
    local config_file="${SETUP_DIR}/${CONFIG_NAME:-${default_config_name}}.conf"
    log "Saving configuration to ${config_file}"
    
cat > "${config_file}" << EOF
# GhostAP Configuration File

INTERFACE="${INTERFACE}"
SSID="${DEFAULTS[SSID]}"
CHANNEL="${DEFAULTS[CHANNEL]}"
SUBNET="${DEFAULTS[SUBNET]}"
DNS="${DEFAULTS[DNS]}"
SECURITY="${DEFAULTS[SECURITY]}"
PASSWORD="${DEFAULTS[PASSWORD]}"
INTERNET_SHARING="${DEFAULTS[INTERNET_SHARING]}"
SOURCE_INTERFACE="${DEFAULTS[SOURCE_INTERFACE]}"
DNS_SPOOFING="${DEFAULTS[DNS_SPOOFING]}"
PACKET_CAPTURE="${DEFAULTS[PACKET_CAPTURE]}"
CAPTURE_FILE="${DEFAULTS[CAPTURE_FILE]}"
MAC="${DEFAULTS[MAC]}"
VPN_ROUTING="${DEFAULTS[VPN_ROUTING]}"
VPN_CONFIG="${DEFAULTS[VPN_CONFIG]}"

# Cloning Options
CLONE="${DEFAULTS[CLONE]}"
CLONE_SSID="${DEFAULTS[CLONE_SSID]}"

# Proxy Options
PROXY_ENABLED="${DEFAULTS[PROXY_ENABLED]}"
PROXY_MODE="${DEFAULTS[PROXY_MODE]}"
PROXY_HOST="${DEFAULTS[PROXY_HOST]}"
PROXY_PORT="${DEFAULTS[PROXY_PORT]}"
PROXY_TYPE="${DEFAULTS[PROXY_TYPE]}"
PROXY_USER="${DEFAULTS[PROXY_USER]}"
PROXY_PASS="${DEFAULTS[PROXY_PASS]}"

# DNS Options
SPOOF_DOMAINS="${DEFAULTS[SPOOF_DOMAINS]}"
SPOOF_TARGET_IP="${DEFAULTS[SPOOF_TARGET_IP]}"
BLOCK_DOH="${DEFAULTS[BLOCK_DOH]}"
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        local key="$1"
        case "${key}" in
            --int|--interactive)
                INTERACTIVE_MODE=true
                shift
                ;;
            --config)
                [[ -z "${2:-}" ]] && error "Missing argument for --config"
                CONFIG_FILE="$2"
                if [[ "${CONFIG_FILE}" != *.* ]]; then
                    CONFIG_FILE="${SETUP_DIR}/${CONFIG_FILE}.conf"
                fi
                [[ -f "${CONFIG_FILE}" ]] || error "Configuration file not found: ${CONFIG_FILE}"
                shift 2
                ;;
            --save)
                [[ -z "${2:-}" ]] && error "Missing argument for --save"
                CONFIG_NAME="$2"
                SAVE_CONFIG=true
                shift 2
                ;;
            -i|--interface)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[INTERFACE]="$2"
                ARG[INTERFACE]=1
                shift 2
                ;;
            -s|--ssid)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[SSID]="$2"
                ARG[SSID]=1
                shift 2
                ;;
            -c|--channel)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[CHANNEL]="$2"
                ARG[CHANNEL]=1
                shift 2
                ;;
            -m|--mac)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                if validate_mac "$2"; then
                    DEFAULTS[MAC]="$2"
                    ARG[MAC]=1
                else
                    error "Invalid MAC address format: $2 (expected XX:XX:XX:XX:XX:XX)"
                fi
                shift 2
                ;;

            --security)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[SECURITY]="$2"
                ARG[SECURITY]=1
                shift 2
                ;;
            --password)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PASSWORD]="$2"
                ARG[PASSWORD]=1
                shift 2
                ;;
            --subnet)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[SUBNET]="$2"
                ARG[SUBNET]=1
                shift 2
                ;;
            --dns)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[DNS]="$2"
                ARG[DNS]=1
                shift 2
                ;;
            --internet)
                DEFAULTS[INTERNET_SHARING]=true
                ARG[INTERNET_SHARING]=1
                shift
                ;;
            -si|--source-interface)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[INTERNET_SHARING]=true
                ARG[INTERNET_SHARING]=1
                DEFAULTS[SOURCE_INTERFACE]="$2"
                ARG[SOURCE_INTERFACE]=1
                shift 2
                ;;
            --capture)
                DEFAULTS[PACKET_CAPTURE]=true
                ARG[PACKET_CAPTURE]=1
                if [[ -n "${2:-}" ]]; then
                    DEFAULTS[CAPTURE_FILE]="$2"
                    ARG[CAPTURE_FILE]=1
                    shift 2
                else
                    shift
                fi
                ;;
            --vpn)
                DEFAULTS[VPN_ROUTING]=true
                ARG[VPN_ROUTING]=1
                if [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]]; then
                    DEFAULTS[VPN_CONFIG]="${2:-}"
                    ARG[VPN_CONFIG]=1
                    shift 2
                else
                    shift
                fi
                ;;
            --spoof)
                DEFAULTS[DNS_SPOOFING]=true
                ARG[DNS_SPOOFING]=1
                # Check if next arg exists and does NOT start with -
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    DEFAULTS[SPOOF_DOMAINS]="$2"
                    ARG[SPOOF_DOMAINS]=1
                    shift 2
                else
                    shift
                fi
                ;;
            --spoof-target)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[SPOOF_TARGET_IP]="$2"
                ARG[SPOOF_TARGET_IP]=1
                shift 2
                ;;
            --block-doh)
                DEFAULTS[BLOCK_DOH]=true
                ARG[BLOCK_DOH]=1
                shift
                ;;
            --clone)
                DEFAULTS[CLONE]=true
                ARG[CLONE]=1
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    DEFAULTS[CLONE_SSID]="$2"
                    ARG[CLONE_SSID]=1
                    shift 2
                else
                    shift
                fi
                ;;
            --local-proxy)
                DEFAULTS[PROXY_MODE]="TRANSPARENT_LOCAL"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_MODE]=1
                shift
                ;;
            --remote-proxy)
                DEFAULTS[PROXY_MODE]="REMOTE_DNAT"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_MODE]=1
                shift
                ;;
            --proxy)
                DEFAULTS[PROXY_MODE]="TRANSPARENT_UPSTREAM"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_MODE]=1
                shift
                ;;
            --proxy-host)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PROXY_HOST]="$2"
                DEFAULTS[PROXY_ENABLED]=true # Implicitly enable proxy if setting host
                ARG[PROXY_HOST]=1
                shift 2
                ;;
            --proxy-port)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PROXY_PORT]="$2"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_PORT]=1
                shift 2
                ;;
            --proxy-type)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PROXY_TYPE]="$2"
                ARG[PROXY_TYPE]=1
                shift 2
                ;;
            --proxy-user)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PROXY_USER]="$2"
                ARG[PROXY_USER]=1
                shift 2
                ;;
            --proxy-pass)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
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
}
