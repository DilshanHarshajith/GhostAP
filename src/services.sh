#!/bin/bash

start_services() {
    log "Starting services..."
    
    if command -v nmcli >/dev/null; then
        nmcli device set "${INTERFACE}" managed no 2>/dev/null || warn "Failed to disable NetworkManager for ${INTERFACE}"
    fi
    
    local retry_count=0
    while [[ ${retry_count} -lt 3 ]]; do
        ip link set "${INTERFACE}" down 2>/dev/null || true
        sleep 1
        
        if ip addr flush dev "${INTERFACE}" && ip addr add "192.168.${SUBNET_OCT}.1/24" dev "${INTERFACE}" && ip link set "${INTERFACE}" up; then
            sleep 2
            if ip addr show "${INTERFACE}" | grep -q "192.168.${SUBNET_OCT}.1"; then
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
    pkill -f "hostapd.*${HOSTAPD_CONF}" 2>/dev/null || true
    sleep 1
    for i in {1..5}; do
        if ! pgrep -f "hostapd.*${HOSTAPD_CONF}" >/dev/null; then
            break
        fi
        warn "Waiting for previous hostapd to exit..."
        sleep 1
    done

    log "Starting hostapd..."
    local hostapd_log="${HOSTAPD_LOG}"
    
    if ! hostapd -B -f "${hostapd_log}" "${HOSTAPD_CONF}"; then
        error "Failed to start hostapd. Check ${hostapd_log} for details."
    fi
    
    sleep 3
    local hostapd_pid
    hostapd_pid=$(pgrep -f "hostapd.*${HOSTAPD_CONF}" | head -1)
    if [[ -n "${hostapd_pid}" ]]; then
        PIDS+=("${hostapd_pid}")
        log "Hostapd started with PID: ${hostapd_pid}"
    else
        error "Hostapd failed to start properly"
    fi
    
    log "Starting dnsmasq..."
    local dnsmasq_log="${DNSMASQ_LOG}"
    
    if ! dnsmasq -C "${DNSMASQ_CONF}" --pid-file="${DNSMASQ_PID_FILE}" --log-facility="${dnsmasq_log}"; then
        error "Failed to start dnsmasq"
    fi
    
    if [[ -f "${DNSMASQ_PID_FILE}" ]]; then
        local dnsmasq_pid
        dnsmasq_pid=$(<"${DNSMASQ_PID_FILE}")
        PIDS+=("${dnsmasq_pid}")
        log "Dnsmasq started with PID: ${dnsmasq_pid}"
    else
        warn "Could not find dnsmasq PID file"
    fi

    log "Applying iptables rules..."
    for rule in "${IPTABLES_RULES[@]}"; do
        debug "Executing rule: ${rule}"
        if ! eval "${rule}" 2>/dev/null; then
            warn "Failed to add iptables rule: ${rule}"
        else
            log "Added iptables rule: ${rule}"
            # Store the reverse command (delete) for cleanup
            APPLIED_RULES+=("${rule/-I/-D}")
            APPLIED_RULES+=("${rule/-A/-D}")
        fi
    done
}
