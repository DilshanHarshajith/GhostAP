#!/bin/bash

configure_hostapd() {
    log "Configuring hostapd..."
    
    local config_file="${HOSTAPD_CONF}"

    local ssid="${DEFAULTS[SSID]}"
    local channel="${DEFAULTS[CHANNEL]}"
    local security="${DEFAULTS[SECURITY]}"
    local password="${DEFAULTS[PASSWORD]}"
    
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ "${DEFAULTS[CLONE]}" != "true" ]]; then
            if [[ -z "${ARG[SSID]}" ]]; then
                read -r -p "SSID [${ssid}]: " user_input
                ssid="${user_input:-${ssid}}"
            fi

            if [[ -z "${ARG[CHANNEL]}" ]]; then
                while true; do
                    read -r -p "Channel [${channel}]: " user_input
                    channel="${user_input:-${channel}}"
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
            
            DEFAULTS[SECURITY]="${security}"
            DEFAULTS[PASSWORD]="${password}"
        fi
    else
        # Non-Interactive Mode Validation
        if [[ "${DEFAULTS[CLONE]}" != "true" ]]; then
            [[ -n "${DEFAULTS[SSID]}" ]] || error "SSID is required in non-interactive mode (use -s or --ssid)"
            [[ -n "${DEFAULTS[CHANNEL]}" ]] || error "Channel is required in non-interactive mode (use -c or --channel)"
            [[ -n "${DEFAULTS[SECURITY]}" ]] || error "Security type is required in non-interactive mode (use --security)"
            
            if [[ "${DEFAULTS[SECURITY]}" != "open" ]]; then
                [[ -n "${DEFAULTS[PASSWORD]}" ]] || error "Password is required for ${DEFAULTS[SECURITY]} in non-interactive mode (use --password)"
            fi
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

    if [[ -z "${ARG[SSID]}" ]]; then
        DEFAULTS[SSID]="${ssid}"
    fi

    if [[ -z "${ARG[CHANNEL]}" ]]; then
        DEFAULTS[CHANNEL]="${channel}"
    fi

    if [[ -z "${ARG[SECURITY]}" ]]; then
        DEFAULTS[SECURITY]="${security}"
    fi

    if [[ -z "${ARG[PASSWORD]}" ]]; then
        DEFAULTS[PASSWORD]="${password}"
    fi

    cat > "${config_file}" << EOF
interface=${INTERFACE}
driver=nl80211
ssid=${ssid}
channel=${channel}
$( [[ -n "${DEFAULTS[MAC]}" ]] && echo "bssid=${DEFAULTS[MAC]}" )
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
