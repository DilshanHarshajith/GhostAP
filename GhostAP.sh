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
    for module in utils network config ui interface scan vpn hostapd dnsmasq internet proxy capture captive services; do
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
    log "PID: $$, User: ${SUDO_USER:-$(whoami)}"
    
    [[ -n "${CONFIG_FILE}" ]] && load_config
    
    configure_interface

    if [[ "${SCAN_APS_ONLY}" == true ]]; then
        scan_show_nearby_aps
        exit $?
    fi

    configure_clone
    configure_hostapd
    configure_mac_in_interactive
    configure_dhcp || warn "DHCP configuration failed — AP may not assign addresses"

    configure_vpn            || warn "VPN feature skipped"
    configure_internet_sharing || warn "Internet sharing feature skipped"
    configure_proxy          || warn "Proxy feature skipped"
    configure_dns_spoof      || warn "DNS spoofing feature skipped"
    configure_captive_portal || warn "Captive portal feature skipped"
    configure_packet_capture || warn "Packet capture feature skipped"

    save_config
    
    start_services    
    
    show_status

    log "Entering main loop, waiting for signals..."

    while true; do
        sleep 3
        
        # Check processes
        for process_pid in "${PIDS[@]}"; do
            if [[ -n "${process_pid}" ]] && ! kill -0 "${process_pid}" 2>/dev/null; then
                warn "Process ${process_pid} died unexpectedly"
            fi
        done
        
        # Refresh the connected-client display every loop.
        # show_connected_clients uses ARP state so clients that left without
        # sending DHCPRELEASE are removed promptly, even if dnsmasq does not
        # rewrite the lease file.
        show_connected_clients
    done
}

main "$@"