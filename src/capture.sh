#!/bin/bash

configure_packet_capture() {    
    if ! command -v tshark >/dev/null; then
        warn "tshark not installed, packet capture will be unavailable"
        return 1
    fi

    if [[ ${INTERACTIVE_MODE} == true ]]; then
        if [[ -z "${ARG[PACKET_CAPTURE]}" ]]; then
            read -r -p "Enable packet capture? (y/N): " enable_capture
            if [[ "${enable_capture}" =~ ^[Yy]$ ]]; then
                DEFAULTS[PACKET_CAPTURE]=true
                read -r -p "Capture file(Default: ${DEFAULTS[CAPTURE_FILE]}): " capture_file
                [[ -n "${capture_file}" ]] && DEFAULTS[CAPTURE_FILE]="${capture_file}"
                log "Capture file set to: ${DEFAULTS[CAPTURE_FILE]}"
                log "Packet Capture Enabled."
            elif [[ "${enable_capture}" =~ ^[Nn]$ ]]; then
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

        # Check if we have necessary permissions
        if [[ ${EUID} -ne 0 ]]; then
            # Check if tshark has capabilities set
            if ! getcap "$(which tshark)" 2>/dev/null | grep -q "cap_net_raw,cap_net_admin"; then
                warn "tshark requires root privileges or CAP_NET_RAW+CAP_NET_ADMIN capabilities"
                warn "Run: sudo setcap cap_net_raw,cap_net_admin+eip \$(which tshark)"
                return 1
            fi
        fi

        # Verify interface exists and is up
        if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
            error "Interface ${INTERFACE} does not exist or is not accessible"
            return 1
        fi

        # Write to /tmp first (proven to work), then move to Output during cleanup
        TMP_CAPTURE="/tmp/$(basename "${DEFAULTS[CAPTURE_FILE]}")"
        CAPTURE_FILE="${DEFAULTS[CAPTURE_FILE]}"

        local capture_log="${TSHARK_LOG}"
        local capture_err="${LOG_DIR}/tshark_error.log"
        
        # Start tshark with proper error logging
        tshark -i "${INTERFACE}" -w "${TMP_CAPTURE}" \
            -f "not arp and not stp" >> "${capture_log}" 2>> "${capture_err}" &
        TSHARK_PID=$!
        
        # Wait a moment and verify tshark is actually running
        local check=0
        while [[ ${check} -lt 3 ]]; do
            sleep 1
            if ! kill -0 "${TSHARK_PID}" 2>/dev/null; then
                warn "tshark process died immediately after starting"
                warn "Check error log: ${capture_err}"
                if [[ -f "${capture_err}" ]]; then
                    warn "Last error: $(tail -3 "${capture_err}")"
                fi
                TSHARK_PID=""
                return 1
            fi
            ((check++))
        done
        
        # Verify the capture file is being created
        local wait_count=0
        while [[ ! -f "${TMP_CAPTURE}" ]] && [[ ${wait_count} -lt 5 ]]; do
            sleep 1
            ((wait_count++))
        done
        
        if [[ ! -f "${TMP_CAPTURE}" ]]; then
            warn "tshark failed to create capture file: ${TMP_CAPTURE}"
            if kill -0 "${TSHARK_PID}" 2>/dev/null; then
                kill "${TSHARK_PID}" 2>/dev/null
            fi
            TSHARK_PID=""
            return 1
        fi
        
        PIDS+=("${TSHARK_PID}")
        log "Packet capture started successfully: ${CAPTURE_FILE} (PID: ${TSHARK_PID})"
    fi
}

move_capture_file() {
    if [[ "${DEFAULTS[PACKET_CAPTURE]}" == true ]]; then
        # Move capture file from /tmp to Output folder
        if [[ -n "${TMP_CAPTURE}" ]] && [[ -f "${TMP_CAPTURE}" ]]; then
            log "Tshark process ${TSHARK_PID} ended, moving capture to ${CAPTURE_FILE}"
            if mv "${TMP_CAPTURE}" "${CAPTURE_FILE}" 2>/dev/null; then
                # Make the file readable by all users (not just root)
                chmod 644 "${CAPTURE_FILE}" 2>/dev/null || true
                log "Capture file moved to: ${CAPTURE_FILE}"
                local file_size
                file_size=$(stat -f%z "${CAPTURE_FILE}" 2>/dev/null || stat -c%s "${CAPTURE_FILE}" 2>/dev/null || echo "unknown")
                log "Capture file size: ${file_size} bytes"
            else
                warn "Failed to move capture file from ${TMP_CAPTURE} to ${CAPTURE_FILE}"
            fi
        elif [[ -n "${TMP_CAPTURE}" ]] && [[ ! -f "${TMP_CAPTURE}" ]]; then
            warn "Capture file ${TMP_CAPTURE} does not exist (tshark may have failed to start)"
        elif [[ -z "${TMP_CAPTURE}" ]]; then
            debug "No capture file path was set (packet capture may not have been enabled)"
        fi
    fi
}
