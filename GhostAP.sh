#!/bin/bash
# GhostAP - A Bash script for creating a WiFi access point with various features

if ((BASH_VERSINFO[0] < 4)); then
    echo "This script requires Bash version 4.0 or newer." >&2
    echo "Your version: ${BASH_VERSION}" >&2
    exit 1
fi

# Determine project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# Source all modules
if [[ -d "${SRC_DIR}" ]]; then
    # globals.sh must be sourced first
    source "${SRC_DIR}/globals.sh" || { echo "Failed to load globals.sh"; exit 1; }
    
    # Source other modules
    for module in utils network config ui interface vpn hostapd dnsmasq internet proxy capture services; do
        if [[ -f "${SRC_DIR}/${module}.sh" ]]; then
            source "${SRC_DIR}/${module}.sh" || { echo "Failed to load ${module}.sh"; exit 1; }
        else
            echo "Error: Module ${module}.sh not found in ${SRC_DIR}" >&2
            exit 1
        fi
    done
else
    echo "Error: Source directory ${SRC_DIR} not found" >&2
    exit 1
fi

main() {
    if [[ -z "${INTERACTIVE_MODE:-}" ]]; then
        [[ -t 0 ]] && INTERACTIVE_MODE=true || INTERACTIVE_MODE=false
    fi

    # Parse Arguments
    parse_arguments "$@"
    
    trap 'handle_signal SIGINT' SIGINT
    trap 'handle_signal SIGTERM' SIGTERM
        
    check_root
    check_dependencies
    
    log "GhostAP starting..."
    log "PID: $$, User: $(whoami)"
    
    if [[ -n "${CONFIG_FILE}" ]]; then
        load_config
        # Sync globals that are commonly used outside the DEFAULTS array
        INTERFACE="${DEFAULTS[INTERFACE]}"
        SOURCE_INTERFACE="${DEFAULTS[SOURCE_INTERFACE]}"
        SPOOF_DOMAINS="${DEFAULTS[SPOOF_DOMAINS]}"
    fi

    configure_interface
    configure_clone
    configure_hostapd
    configure_mac_in_interactive
    configure_dhcp

    configure_vpn
    configure_internet_sharing
    configure_proxy
    configure_dns_spoof
    configure_doh_blocking
    configure_packet_capture

    save_config
    
    start_services    
    
    show_status

    log "Entering main loop, waiting for signals..."
    local dhcp_lease_file="${TMP_DIR}/dhcp.leases"
    local last_lease_chksum=""
    
    while true; do
        sleep 5
        
        # Check processes
        for process_pid in "${PIDS[@]}"; do
            if [[ -n "${process_pid}" ]] && ! kill -0 "${process_pid}" 2>/dev/null; then
                warn "Process ${process_pid} died unexpectedly"
            fi
        done
        
        # Monitor Connected Devices
        if [[ -f "${dhcp_lease_file}" ]]; then
             local current_chksum=$(md5sum "${dhcp_lease_file}" | awk '{print $1}')
             if [[ "${current_chksum}" != "${last_lease_chksum}" ]]; then
                last_lease_chksum="${current_chksum}"
                show_connected_clients
             fi
        fi
    done
}

main "$@"