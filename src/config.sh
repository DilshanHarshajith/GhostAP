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
                ARG[${key}]=1
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
    [[ "${SAVE_CONFIG}" == true ]] || return 0
    log "Saving current configuration..."
    local config_file="${CONFIG_DIR}/${CONFIG_NAME:-default}.conf"
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

# Cloning Options
CLONE="${DEFAULTS[CLONE]}"
CLONE_SSID="${DEFAULTS[CLONE_SSID]}"

# Proxy Options
PROXY_ENABLED="${DEFAULTS[PROXY_ENABLED]}"
PROXY_MODE="${DEFAULTS[PROXY_MODE]}"
PROXY_BACKEND="${DEFAULTS[PROXY_BACKEND]}"
MITM_LOCATION="${DEFAULTS[MITM_LOCATION]}"
START_MITM_AUTO="${DEFAULTS[START_MITM_AUTO]}"
PROXY_HOST="${DEFAULTS[PROXY_HOST]}"
PROXY_PORT="${DEFAULTS[PROXY_PORT]}"
PROXY_TYPE="${DEFAULTS[PROXY_TYPE]}"
PROXY_USER="${DEFAULTS[PROXY_USER]}"
PROXY_PASS="${DEFAULTS[PROXY_PASS]}"

# DNS Options
SPOOF_DOMAINS="${DEFAULTS[SPOOF_DOMAINS]}"
EOF
}

parse_arguments() {
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
                    DEFAULTS[CLONE]=true
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
                    DEFAULTS[SPOOF_DOMAINS]="$2"
                    ARG[SPOOF_DOMAINS]=1
                    shift 2
                else
                    shift
                fi
                DEFAULTS[DNS_SPOOFING]=true
                ARG[DNS_SPOOFING]=1
                ;;
            --mitm-auto)
                if [[ -n "${2:-}" && "$2" =~ ^(true|false)$ ]]; then
                    DEFAULTS[START_MITM_AUTO]="$2"
                    ARG[START_MITM_AUTO]=1
                    shift 2
                else
                    DEFAULTS[START_MITM_AUTO]=true
                    ARG[START_MITM_AUTO]=1
                    shift
                fi
                ;;
            --proxy-mode)
                if [[ -z "${2:-}" ]]; then
                    error "No proxy mode specified after $1"
                fi
                DEFAULTS[PROXY_MODE]="$2"
                ARG[PROXY_MODE]=1
                shift 2
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
}
