#!/bin/bash

load_config() {
    [[ -f "${CONFIG_FILE}" ]] || return 0
    
    log "Loading configuration from ${CONFIG_FILE}"
    while IFS= read -r line; do
        # Skip blank lines and comments
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Split on the FIRST '=' only — preserves values that contain '='
        # (passwords, SPOOF_DOMAINS entries like domain.com=1.2.3.4, etc.)
        local key="${line%%=*}"
        local value="${line#*=}"

        # Trim whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        # Trim whitespace and surrounding quotes from value
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        if [[ -v DEFAULTS[${key}] ]]; then
            # Priority: CLI arguments (ARG) > Config file > Defaults
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

	{
		echo "# GhostAP Configuration File"
		echo

		while IFS= read -r key; do
			printf '%s="%s"\n' "$key" "${DEFAULTS[$key]}"
		done < <(printf '%s\n' "${!DEFAULTS[@]}" | LC_ALL=C sort)
	} > "$config_file"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        local key="$1"
        case "${key}" in
            --int|--interactive)
                INTERACTIVE_MODE=true
                shift
                ;;
            --eth-ap|--ethernet-ap)
                DEFAULTS[ETHERNET_MODE]=true
                ARG[ETHERNET_MODE]=1
                shift
                ;;
            --config)
                [[ -z "${2:-}" ]] && error "Missing argument for --config"
                CONFIG_FILE="$2"
                if [[ "${CONFIG_FILE}" != *.* ]]; then
                    CONFIG_FILE="${SETUP_DIR}/${CONFIG_FILE}.conf"
                elif [[ "${CONFIG_FILE}" != ^/*.* ]]; then
                    CONFIG_FILE="${WORKING_DIR}/${CONFIG_FILE}"
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
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
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
            --vpn-interface)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[VPN_ROUTING]=true
                ARG[VPN_ROUTING]=1
                DEFAULTS[VPN_INTERFACE]="${2}"
                ARG[VPN_INTERFACE]=1
                shift 2
                ;;
            --vpn-creds)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[VPN_CREDS]="${2}"
                ARG[VPN_CREDS]=1
                shift 2
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
            --captive)
                DEFAULTS[CAPTIVE_PORTAL]=true
                ARG[CAPTIVE_PORTAL]=1
                shift
                ;;
            --captive-port)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[CAPTIVE_PORT]="$2"
                ARG[CAPTIVE_PORT]=1
                DEFAULTS[CAPTIVE_PORTAL]=true
                ARG[CAPTIVE_PORTAL]=1
                shift 2
                ;;
            --captive-template)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                [[ ! -f "$2" ]] && error "Captive portal template not found: $2"
                DEFAULTS[CAPTIVE_TEMPLATE]="$2"
                DEFAULTS[CAPTIVE_PORTAL]=true
                ARG[CAPTIVE_TEMPLATE]=1
                ARG[CAPTIVE_PORTAL]=1
                shift 2
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
                ARG[PROXY_ENABLED]=1
                ARG[PROXY_MODE]=1
                shift
                ;;
            --remote-proxy)
                DEFAULTS[PROXY_MODE]="REMOTE_DNAT"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_ENABLED]=1
                ARG[PROXY_MODE]=1
                shift
                ;;
            --proxy)
                DEFAULTS[PROXY_MODE]="TRANSPARENT_UPSTREAM"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_ENABLED]=1
                ARG[PROXY_MODE]=1
                shift
                ;;
            --proxy-host)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PROXY_HOST]="$2"
                DEFAULTS[PROXY_ENABLED]=true # Implicitly enable proxy if setting host
                ARG[PROXY_ENABLED]=1
                ARG[PROXY_HOST]=1
                shift 2
                ;;
            --proxy-port)
                [[ -z "${2:-}" ]] && error "Missing argument for $1"
                DEFAULTS[PROXY_PORT]="$2"
                DEFAULTS[PROXY_ENABLED]=true
                ARG[PROXY_ENABLED]=1
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