#!/bin/bash

# AP scanning
# ------------------------------------------------------------------
# All over-the-air AP discovery lives here: entering/exiting monitor
# mode, channel hopping, and a tshark capture that parses beacon frames
# for BSSID/SSID/channel/security/signal.
#
# The functions below are split into two layers:
#   - scan_* / _scan_*   Universal primitives. No knowledge of cloning,
#                         hostapd, or any particular feature — usable
#                         anywhere GhostAP needs to know what access
#                         points are nearby (clone target discovery, the
#                         standalone AP survey via --scan-aps, or any
#                         future feature that needs the same data).
#   - configure_clone_*  Feature-specific consumers that call the
#                         universal primitives and apply the result to
#                         DEFAULTS for cloning.
#
# Only use against networks/devices you own or are explicitly
# authorized to test.

declare -g SCAN_HOPPER_PID=""
declare -g SCAN_TSHARK_PID=""
declare -g SCAN_FIELDS_FILE=""

# Default duration (seconds) for the non-live "quick" scans used by the
# plain interactive picker and explicit --clone "SSID" resolution. These
# need monitor mode + a capture window (unlike the old instant iwlist
# scan), so keep it short but long enough to reliably catch a beacon
# (APs typically beacon every ~100ms, but channel hopping means we're
# not always listening on the right channel).
declare -g CLONE_QUICK_SCAN_DURATION=10

# BSSID -> "ssid|channel|security|signal" (from beacon frames)
declare -g -A SCAN_AP_INFO
# Sorted "bssid|ssid|channel|security|signal" rows, built on demand from
# SCAN_AP_INFO via scan_build_sorted_table.
declare -g -a SCAN_AP_TABLE=()

# ============================================================
# Universal scanning primitives
# ============================================================

_scan_decode_ssid() {
    local raw="${1:-}"
    [[ -z "${raw}" ]] && { printf '%s' ""; return 0; }

    local cleaned="${raw//[$'\r\n']/}"
    cleaned="${cleaned//$'\t'/}"

    if [[ "${cleaned}" =~ ^[0-9A-Fa-f]+$ ]] && (( ${#cleaned} % 2 == 0 )); then
        if command -v xxd >/dev/null 2>&1; then
            printf '%s' "${cleaned}" | xxd -r -p 2>/dev/null || printf '%s' "${cleaned}"
        elif command -v python3 >/dev/null 2>&1; then
            python3 -c 'import sys; import binascii; raw=sys.argv[1].strip(); sys.stdout.write(bytes.fromhex(raw).decode("utf-8", "replace"))' "${cleaned}"
        else
            printf '%s' "${cleaned}"
        fi
    else
        printf '%s' "${cleaned}"
    fi
}

_scan_classify_security() {
    local privacy="${1:-0}"
    local rsn_akms="${2:-}"
    local rsn_akm_oui="${3:-}"
    local rsn_akm_type="${4:-}"

    local normalized_privacy="${privacy,,}"
    normalized_privacy="${normalized_privacy//[[:space:]]/}"

    if [[ "${normalized_privacy}" == "0" || "${normalized_privacy}" == "off" || "${normalized_privacy}" == "false" || "${normalized_privacy}" == "no" ]]; then
        printf 'open'
        return 0
    fi

    local akm_oui="${rsn_akm_oui:-}"
    local akm_type="${rsn_akm_type:-}"

    if [[ -n "${akm_oui}" && -n "${akm_type}" ]]; then
        akm_oui="${akm_oui//[[:space:]]/}"
        akm_type="${akm_type//[[:space:]]/}"
        akm_oui="${akm_oui//0x/}"
        akm_type="${akm_type//0x/}"
        akm_oui="${akm_oui,,}"
        akm_type="${akm_type,,}"

        if [[ "${akm_oui}" == "00:0f:ac" || "${akm_oui}" == "000fac" || "${akm_oui}" == "000fac08" ]]; then
            case "${akm_type}" in
                1|2)
                    printf 'wpa2'
                    ;;
                8|9|13|15)
                    printf 'wpa3'
                    ;;
                *)
                    printf 'wpa2'
                    ;;
            esac
            return 0
        fi
    fi

    if [[ -n "${rsn_akms}" ]]; then
        local normalized="${rsn_akms//[[:space:]]/}"
        normalized="${normalized//0x/}"
        normalized="${normalized,,}"

        if [[ "${normalized}" == *"000fac08"* ]] || [[ "${normalized}" == *"000fac09"* ]] || [[ "${normalized}" == *"000fac0d"* ]] || [[ "${normalized}" == *"000fac0f"* ]] || [[ "${normalized}" == *"sae"* ]]; then
            printf 'wpa3'
            return 0
        fi
    fi

    printf 'wpa2'
}

_scan_channels() {
    # 2.4GHz always; append 5GHz UNII-1 if the card reports support for it
    local chans=(1 2 3 4 5 6 7 8 9 10 11)
    if iw phy 2>/dev/null | grep -q "5180 MHz"; then
        chans+=(36 40 44 48)
    fi
    printf '%s\n' "${chans[@]}"
}

_scan_enter_monitor_mode() {
    local iface="$1"
    if command -v nmcli >/dev/null; then
        nmcli device set "${iface}" managed no 2>/dev/null || true
    fi
    ip link set "${iface}" down || return 1
    if ! iw dev "${iface}" set type monitor; then
        warn "Failed to set ${iface} to monitor mode (driver may not support it)."
        ip link set "${iface}" up 2>/dev/null || true
        return 1
    fi
    ip link set "${iface}" up || return 1
    return 0
}

_scan_exit_monitor_mode() {
    local iface="$1"
    [[ -n "${iface}" ]] || return 0
    ip link set "${iface}" down 2>/dev/null || true
    iw dev "${iface}" set type managed 2>/dev/null || true
    ip link set "${iface}" up 2>/dev/null || true
}

_scan_start_hopper() {
    local iface="$1"
    local -a chans
    mapfile -t chans < <(_scan_channels)

    (
        while true; do
            for ch in "${chans[@]}"; do
                iw dev "${iface}" set channel "${ch}" 2>/dev/null
                sleep 0.4
            done
        done
    ) &
    SCAN_HOPPER_PID=$!
}

_scan_start_capture() {
    local iface="$1"
    SCAN_FIELDS_FILE="${TMP_DIR}/scan_live.tsv"
    : > "${SCAN_FIELDS_FILE}"

    # type_subtype: 0x08 = beacon
    tshark -i "${iface}" -l \
        -Y "wlan.fc.type_subtype == 0x08" \
        -T fields -E separator=/t \
        -e wlan.bssid -e wlan.ssid \
        -e radiotap.dbm_antsignal -e wlan.ds.current_channel \
        -e wlan.fixed.capabilities.privacy -e wlan.rsn.akms \
        -e wlan.rsn.akms.oui -e wlan.rsn.akms.type \
        >> "${SCAN_FIELDS_FILE}" 2>>"${TSHARK_LOG}" &
    SCAN_TSHARK_PID=$!

    sleep 1
    if ! kill -0 "${SCAN_TSHARK_PID}" 2>/dev/null; then
        warn "tshark failed to start for AP scan capture. Check ${TSHARK_LOG}"
        return 1
    fi
    return 0
}

_scan_stop_background() {
    [[ -n "${SCAN_HOPPER_PID}" ]] && kill "${SCAN_HOPPER_PID}" 2>/dev/null
    wait "${SCAN_HOPPER_PID}" 2>/dev/null
    SCAN_HOPPER_PID=""

    [[ -n "${SCAN_TSHARK_PID}" ]] && kill "${SCAN_TSHARK_PID}" 2>/dev/null
    wait "${SCAN_TSHARK_PID}" 2>/dev/null
    SCAN_TSHARK_PID=""
}

# Re-parse the full fields file each refresh (simple and robust — files
# stay small for a scan session measured in tens of seconds to a couple
# minutes).
_scan_refresh_data() {
    SCAN_AP_INFO=()

    [[ -s "${SCAN_FIELDS_FILE}" ]] || return 0

    while IFS=$'\t' read -r bssid ssid signal channel privacy rsn_akms rsn_akm_oui rsn_akm_type; do
        [[ -z "${bssid}" ]] && continue

        local decoded_ssid
        decoded_ssid="$(_scan_decode_ssid "${ssid}")"
        [[ -z "${decoded_ssid}" ]] && continue

        local security
        security="$(_scan_classify_security "${privacy}" "${rsn_akms}" "${rsn_akm_oui}" "${rsn_akm_type}")"
        SCAN_AP_INFO["${bssid}"]="${decoded_ssid}|${channel:-?}|${security}|${signal:-N/A}"
    done < "${SCAN_FIELDS_FILE}"
}

scan_render_table() {
    local header="${1:-Live AP scan — press any key to stop}"

    tput cup 0 0 2>/dev/null || clear
    tput ed 2>/dev/null

    {
        echo "${header}"
        echo
        printf "%-18s %-35s %-4s %-8s %-8s\n" "BSSID" "SSID" "CH" "SEC" "SIGNAL"
        printf '%s\n' "----------------------------------------------------------------"

        local rows=""
        for bssid in "${!SCAN_AP_INFO[@]}"; do
            IFS='|' read -r ssid channel security signal <<< "${SCAN_AP_INFO[${bssid}]}"
            rows+="${signal}\t${bssid}|${ssid}|${channel}|${security}|${signal}\n"
        done

        if [[ -z "${rows}" ]]; then
            echo "(no beacons captured yet...)"
        else
            printf '%b' "${rows}" | sort -t$'\t' -k1,1nr | cut -f2- | \
            while IFS='|' read -r bssid ssid channel security signal; do
                printf "%-18s %-35s %-4s %-8s %-8s\n" "${bssid}" "${ssid:-<hidden>}" "${channel}" "${security}" "${signal}"
            done
        fi
    } >&2
}

# Builds the final sorted table from current SCAN_AP_INFO (sorted by
# signal strength, strongest first), for callers to consume after a scan.
scan_build_sorted_table() {
    SCAN_AP_TABLE=()
    for bssid in "${!SCAN_AP_INFO[@]}"; do
        IFS='|' read -r ssid channel security signal <<< "${SCAN_AP_INFO[${bssid}]}"
        SCAN_AP_TABLE+=("${bssid}|${ssid}|${channel}|${security}|${signal}")
    done
    [[ ${#SCAN_AP_TABLE[@]} -eq 0 ]] && return 0
    mapfile -t SCAN_AP_TABLE < <(printf '%s\n' "${SCAN_AP_TABLE[@]}" | sort -t'|' -k5,5nr)
}

# Converts SCAN_AP_TABLE rows into human-readable "SSID | BSSID | chN |
# SEC | dBm" labels suitable for select_from_list(). Universal helper
# shared by every picker that presents scan results to the user.
scan_table_to_labels() {
    local entry bssid ssid channel security signal
    for entry in "${SCAN_AP_TABLE[@]}"; do
        IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
        printf '%s\n' "${ssid:-<hidden>} | ${bssid} | ch${channel} | ${security} | ${signal}dBm"
    done
}

# Given a label previously produced by scan_table_to_labels, echoes the
# matching SCAN_AP_TABLE row (bssid|ssid|channel|security|signal).
# Returns 1 if no match is found.
scan_table_row_for_label() {
    local target_label="$1"
    local i entry bssid ssid channel security signal label
    for i in "${!SCAN_AP_TABLE[@]}"; do
        entry="${SCAN_AP_TABLE[$i]}"
        IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
        label="${ssid:-<hidden>} | ${bssid} | ch${channel} | ${security} | ${signal}dBm"
        if [[ "${label}" == "${target_label}" ]]; then
            printf '%s\n' "${entry}"
            return 0
        fi
    done
    return 1
}

# Runs monitor mode + channel hopper + tshark beacon capture for
# `duration` seconds with no live rendering, then restores managed mode.
# Populates SCAN_AP_INFO on success. Universal — used by every non-live
# scan consumer (the quick interactive clone picker, explicit --clone
# "SSID" resolution, and the standalone --scan-aps survey).
scan_run_background() {
    local iface="$1"
    local duration="$2"

    command -v tshark >/dev/null || {
        warn "tshark not installed; cannot run a scan."
        return 1
    }

    _scan_enter_monitor_mode "${iface}" || return 1

    _scan_start_hopper "${iface}"
    if ! _scan_start_capture "${iface}"; then
        _scan_stop_background
        _scan_exit_monitor_mode "${iface}"
        return 1
    fi

    # Ensure background jobs die even if the user Ctrl-C's out mid-scan
    trap '_scan_stop_background; _scan_exit_monitor_mode "'"${iface}"'"; exit 130' INT

    local elapsed=0
    while (( elapsed < duration )); do
        sleep 1
        ((elapsed++))
    done
    _scan_refresh_data

    trap - INT

    _scan_stop_background
    _scan_exit_monitor_mode "${iface}"
    log "Restored ${iface} to managed mode."
    return 0
}

# Live, continuously-updating scan: enters monitor mode, hops channels,
# captures beacons, and re-renders scan_render_table roughly once per
# second until any key is pressed, then restores managed mode. Universal
# — used by the live clone picker and the standalone --scan-aps survey;
# any future feature that wants a live nearby-AP view can call this
# directly. Populates SCAN_AP_INFO; callers should call
# scan_build_sorted_table afterward to consume the result.
scan_run_live() {
    local iface="$1"
    local header="${2:-Live AP scan — press any key to stop}"

    command -v tshark >/dev/null || {
        warn "tshark not installed; cannot run a live scan."
        return 1
    }

    log "Switching ${iface} to monitor mode for live scan..."
    _scan_enter_monitor_mode "${iface}" || return 1

    _scan_start_hopper "${iface}"
    if ! _scan_start_capture "${iface}"; then
        _scan_stop_background
        _scan_exit_monitor_mode "${iface}"
        return 1
    fi

    trap '_scan_stop_background; _scan_exit_monitor_mode "'"${iface}"'"; exit 130' INT

    clear
    local key=""
    while true; do
        _scan_refresh_data
        scan_render_table "${header}"
        # 1s refresh interval, doubling as the keypress poll
        if read -r -t 1 -n 1 -s key; then
            break
        fi
    done

    trap - INT

    _scan_stop_background
    _scan_exit_monitor_mode "${iface}"
    clear
    log "Restored ${iface} to managed mode."
    return 0
}

# Standalone AP survey: scans and prints a snapshot of nearby access
# points, then returns — no cloning, no AP setup. Demonstrates that the
# primitives above are genuinely reusable outside the cloning flow.
# Triggered by --scan-aps [SECONDS].
scan_show_nearby_aps() {
    if [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]]; then
        warn "Ethernet AP mode has no radio to scan with."
        return 1
    fi
    command -v tshark >/dev/null || {
        warn "tshark not installed; cannot scan for nearby access points."
        return 1
    }

    local iface="${DEFAULTS[INTERFACE]}"

    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        scan_run_live "${iface}" "Live AP scan — press any key to stop" || return 1
    else
        local duration="${SCAN_APS_DURATION:-15}"
        log "Scanning for nearby access points (${duration}s)..."
        scan_run_background "${iface}" "${duration}" || return 1
    fi

    scan_build_sorted_table
    [[ ${#SCAN_AP_TABLE[@]} -gt 0 ]] || { warn "No nearby access points found."; return 1; }

    {
        echo
        printf "%-18s %-35s %-4s %-8s %-8s\n" "BSSID" "SSID" "CH" "SEC" "SIGNAL"
        printf '%s\n' "----------------------------------------------------------------"
        for entry in "${SCAN_AP_TABLE[@]}"; do
            IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
            printf "%-18s %-35s %-4s %-8s %-8s\n" "${bssid}" "${ssid:-<hidden>}" "${channel}" "${security}" "${signal}"
        done
    } >&2
    return 0
}

# ============================================================
# Clone-specific consumers
# ============================================================
# Everything below applies scan results to DEFAULTS for cloning.

# Applies a resolved (ssid, channel, mac, security) tuple to DEFAULTS,
# honoring any values the user already gave explicitly via CLI (--ssid,
# --channel, --mac, --security) and warning if a WPA password is still
# needed. Used by every clone-resolution path so behavior — including
# respecting explicit overrides — stays consistent regardless of how the
# target AP was found.
_scan_apply_clone_selection() {
    local ssid="$1" channel="$2" mac="$3" security="$4"

    DEFAULTS[CLONE_SSID]="${ssid}"

    if [[ -z "${ARG[SSID]}" ]]; then
        DEFAULTS[SSID]="${ssid}"
    else
        log "Preserving specified SSID: ${DEFAULTS[SSID]} (ignoring clone SSID: ${ssid})"
    fi

    if [[ -z "${ARG[CHANNEL]}" ]]; then
        DEFAULTS[CHANNEL]="${channel}"
    else
        log "Preserving specified Channel: ${DEFAULTS[CHANNEL]} (ignoring clone Channel: ${channel})"
    fi

    if [[ -z "${ARG[MAC]}" ]]; then
        DEFAULTS[MAC]="${mac}"
    else
        log "Preserving specified MAC: ${DEFAULTS[MAC]} (ignoring clone MAC: ${mac})"
    fi

    if [[ -z "${ARG[SECURITY]}" ]]; then
        DEFAULTS[SECURITY]="${security:-open}"
        log "Cloned security type: ${DEFAULTS[SECURITY]}"
    else
        log "Preserving specified security type: ${DEFAULTS[SECURITY]} (ignoring clone security: ${security})"
    fi

    if [[ "${DEFAULTS[SECURITY]}" != "open" && -z "${DEFAULTS[PASSWORD]}" ]]; then
        warn "Cloned network '${ssid}' uses ${DEFAULTS[SECURITY]} — its password can't be sniffed from a scan."
        warn "You must supply the real password with --password (or you'll be prompted if running interactively)."
    fi

    log "Cloning interface ${DEFAULTS[INTERFACE]} with SSID: ${DEFAULTS[SSID]}, Channel: ${DEFAULTS[CHANNEL]}, MAC: ${DEFAULTS[MAC]}, Security: ${DEFAULTS[SECURITY]}"
}

# Interactive live-scan clone picker: shows a continuously updating table
# of nearby APs until any key is pressed, then lets the user pick one.
configure_clone_live_scan() {
    [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]] && return 1
    command -v tshark >/dev/null || {
        warn "tshark not installed; falling back to standard clone selection."
        return 1
    }

    local iface="${DEFAULTS[INTERFACE]}"

    scan_run_live "${iface}" "Live AP scan — press any key to stop and select a target to clone" || return 1

    scan_build_sorted_table
    [[ ${#SCAN_AP_TABLE[@]} -gt 0 ]] || { warn "No APs captured during scan."; return 1; }

    local labels=()
    mapfile -t labels < <(scan_table_to_labels)

    local choice
    choice=$(select_from_list "Select AP to clone:" "${labels[@]}")

    local row
    row="$(scan_table_row_for_label "${choice}")" || return 1

    local bssid ssid channel security signal
    IFS='|' read -r bssid ssid channel security signal <<< "${row}"

    log "Selected for cloning: SSID='${ssid}' BSSID=${bssid} CH=${channel} SEC=${security}"
    _scan_apply_clone_selection "${ssid}" "${channel}" "${bssid}" "${security}"

    return 0
}

# Default interactive clone-target picker: runs a short, non-live scan
# and presents a plain selection list. Replaces the old iwlist-based
# get_wifi_ssids()/get_ap_info() flow — every clone path shares one
# accurate source of AP info (real signal, real WPA2-vs-WPA3
# classification, and exact BSSID, which avoids ambiguity when multiple
# nearby APs broadcast the same SSID).
configure_clone_quick_scan() {
    [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]] && return 1

    local iface="${DEFAULTS[INTERFACE]}"
    log "Scanning for nearby access points (${CLONE_QUICK_SCAN_DURATION}s)..."
    scan_run_background "${iface}" "${CLONE_QUICK_SCAN_DURATION}" || return 1

    scan_build_sorted_table
    [[ ${#SCAN_AP_TABLE[@]} -gt 0 ]] || { warn "No nearby access points found."; return 1; }

    local labels=()
    mapfile -t labels < <(scan_table_to_labels)

    local choice
    choice=$(select_from_list "Select Access Point for cloning interface:" "${labels[@]}")

    local row
    row="$(scan_table_row_for_label "${choice}")" || return 1

    local bssid ssid channel security signal
    IFS='|' read -r bssid ssid channel security signal <<< "${row}"

    log "Selected Access Point for cloning: ${ssid} (${bssid})"
    _scan_apply_clone_selection "${ssid}" "${channel}" "${bssid}" "${security}"
    return 0
}

# Resolves an explicitly-given SSID (from --clone "SSID" or a loaded
# config file) to full AP details (BSSID, channel, security, signal) via
# a short scan, replacing the old iwlist-based get_ap_info() lookup. If
# multiple nearby APs share the SSID, the strongest-signal match is used
# and the ambiguity is logged rather than silently picking one.
configure_clone_resolve_target() {
    local target_ssid="$1"
    [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]] && return 1

    local iface="${DEFAULTS[INTERFACE]}"
    log "Scanning for '${target_ssid}' (${CLONE_QUICK_SCAN_DURATION}s)..."
    scan_run_background "${iface}" "${CLONE_QUICK_SCAN_DURATION}" || return 1

    scan_build_sorted_table
    [[ ${#SCAN_AP_TABLE[@]} -gt 0 ]] || return 1

    local -a matches=()
    for entry in "${SCAN_AP_TABLE[@]}"; do
        IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
        [[ "${ssid}" == "${target_ssid}" ]] && matches+=("${entry}")
    done

    [[ ${#matches[@]} -gt 0 ]] || return 1

    if [[ ${#matches[@]} -gt 1 ]]; then
        local first_bssid
        first_bssid="$(cut -d'|' -f1 <<< "${matches[0]}")"
        warn "Multiple access points broadcasting SSID '${target_ssid}' were found (${#matches[@]} matches)."
        warn "Using the strongest-signal match: BSSID ${first_bssid}. Use the interactive live scan (--int --clone) to pick a specific one instead."
    fi

    # matches[] preserves SCAN_AP_TABLE's sort order (signal desc), so
    # the first match is the best candidate.
    local bssid ssid channel security signal
    IFS='|' read -r bssid ssid channel security signal <<< "${matches[0]}"

    _scan_apply_clone_selection "${ssid}" "${channel}" "${bssid}" "${security}"
    return 0
}
