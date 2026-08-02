#!/bin/bash

# AP scanning
# ------------------------------------------------------------------
# All over-the-air AP discovery lives here: entering/exiting monitor
# mode and an airodump-ng capture (CSV output) that supplies
# BSSID/SSID/channel/security/signal. airodump-ng owns channel hopping
# itself (restricted to the same channel set GhostAP used to hop
# manually), so there is no separate hopper process to manage.
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

declare -g SCAN_AIRODUMP_PID=""
declare -g SCAN_CSV_PREFIX=""

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

    # airodump-ng's CSV already gives plain ESSID text (blank for hidden
    # networks) — just strip line endings and trim surrounding whitespace.
    local cleaned="${raw//[$'\r\n']/}"
    cleaned="${cleaned//$'\t'/}"
    cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
    cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"

    printf '%s' "${cleaned}"
}

# Classifies security from airodump-ng's CSV "Privacy" and "Authentication"
# columns (e.g. Privacy: OPN/WEP/WPA/WPA2/WPA3, Authentication: PSK/MGT/SAE).
_scan_classify_security() {
    local privacy="${1:-}"
    local auth="${2:-}"

    local p="${privacy^^}"
    p="${p//[[:space:]]/}"
    local a="${auth^^}"
    a="${a//[[:space:]]/}"

    if [[ -z "${p}" || "${p}" == "OPN" ]]; then
        printf 'open'
        return 0
    fi

    # SAE (WPA3-Personal) shows up in Authentication; airodump also marks
    # transitional/WPA3 networks directly in Privacy (e.g. "WPA2WPA3").
    if [[ "${a}" == *"SAE"* || "${p}" == *"WPA3"* ]]; then
        printf 'wpa3'
        return 0
    fi

    # WEP/WPA/WPA2/enterprise all fall back to wpa2 here, same as before —
    # GhostAP only ever needs to distinguish open/wpa2/wpa3 for cloning.
    printf 'wpa2'
}

# Comma-separated channel list passed to airodump-ng's -c flag, restricting
# the hop set to the same channels GhostAP used to hop manually.
_scan_channel_list() {
    local chans=(1 2 3 4 5 6 7 8 9 10 11)
    if iw phy 2>/dev/null | grep -q "5180 MHz"; then
        chans+=(36 40 44 48)
    fi
    local IFS=,
    printf '%s' "${chans[*]}"
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

_scan_start_capture() {
    local iface="$1"

    # Fresh, unique prefix per scan session — airodump-ng writes
    # "${prefix}-01.csv" and we don't want stale data from a previous run
    # bleeding into this one (or -02/-03 rollover if a prefix is reused).
    SCAN_CSV_PREFIX="${TMP_DIR}/scan_airodump_$$_$(date +%s%N)"

    local chanlist
    chanlist="$(_scan_channel_list)"

    airodump-ng --write "${SCAN_CSV_PREFIX}" --output-format csv \
        -c "${chanlist}" "${iface}" \
        >> "${AIRODUMP_LOG}" 2>&1 &
    SCAN_AIRODUMP_PID=$!

    sleep 1
    if ! kill -0 "${SCAN_AIRODUMP_PID}" 2>/dev/null; then
        warn "airodump-ng failed to start for AP scan capture. Check ${AIRODUMP_LOG}"
        SCAN_AIRODUMP_PID=""
        return 1
    fi

    # airodump-ng writes the CSV file once it has something to say —
    # give it a moment before callers start polling _scan_refresh_data.
    local wait_count=0
    while [[ ! -f "${SCAN_CSV_PREFIX}-01.csv" ]] && [[ ${wait_count} -lt 5 ]]; do
        sleep 1
        ((wait_count++))
    done

    return 0
}

_scan_stop_background() {
    if [[ -n "${SCAN_AIRODUMP_PID}" ]]; then
        kill "${SCAN_AIRODUMP_PID}" 2>/dev/null
        wait "${SCAN_AIRODUMP_PID}" 2>/dev/null
    fi
    SCAN_AIRODUMP_PID=""

    # Clean up the CSV (and any airodump sibling files) for this session
    [[ -n "${SCAN_CSV_PREFIX}" ]] && rm -f "${SCAN_CSV_PREFIX}"-*
    SCAN_CSV_PREFIX=""
}

# Parses the AP block of an airodump-ng CSV (--output-format csv) into
# "bssid<US>ssid<US>channel<US>privacy<US>auth<US>power" rows (\037 unit
# separator — see the note below on why not tab), stopping at the blank
# line that separates the AP table from the station table. airodump-ng
# writes CRLF line endings and ", " (comma-space) field separators.
_scan_parse_airodump_csv() {
    local csv_file="$1"
    [[ -s "${csv_file}" ]] || return 0

    awk -F', ' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        { sub(/\r$/, "") }
        /^BSSID/ { in_ap = 1; next }
        /^Station MAC/ { in_ap = 0 }
        !NF { in_ap = 0 }
        in_ap && NF >= 14 {
            bssid = trim($1)
            if (bssid !~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) next
            channel = trim($4)
            privacy = trim($6)
            auth    = trim($8)
            power   = trim($9)
            essid   = trim($14)
            # Use \037 (unit separator) rather than a tab: tab is an IFS
            # whitespace char, so bash'"'"'s "read" squeezes consecutive
            # tabs and misaligns rows with an empty field (hidden SSIDs).
            printf "%s\037%s\037%s\037%s\037%s\037%s\n", bssid, essid, channel, privacy, auth, power
        }
    ' "${csv_file}"
}

# Re-parse the full CSV file each refresh (simple and robust — files stay
# small for a scan session measured in tens of seconds to a couple minutes).
_scan_refresh_data() {
    SCAN_AP_INFO=()

    local csv_file="${SCAN_CSV_PREFIX}-01.csv"
    [[ -s "${csv_file}" ]] || return 0

    while IFS=$'\037' read -r bssid essid channel privacy auth power; do
        [[ -z "${bssid}" ]] && continue

        local decoded_ssid
        decoded_ssid="$(_scan_decode_ssid "${essid}")"
        [[ -z "${decoded_ssid}" ]] && continue

        local security
        security="$(_scan_classify_security "${privacy}" "${auth}")"
        SCAN_AP_INFO["${bssid}"]="${decoded_ssid}|${channel:-?}|${security}|${power:-N/A}"
    done < <(_scan_parse_airodump_csv "${csv_file}")
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

# Runs monitor mode + an airodump-ng beacon capture for `duration` seconds
# with no live rendering, then restores managed mode. Populates
# SCAN_AP_INFO on success. Universal — used by every non-live scan
# consumer (the quick interactive clone picker, explicit --clone "SSID"
# resolution, and the standalone --scan-aps survey).
scan_run_background() {
    local iface="$1"
    local duration="$2"

    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; cannot run a scan."
        return 1
    }

    _scan_enter_monitor_mode "${iface}" || return 1

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

# Live, continuously-updating scan: enters monitor mode, runs airodump-ng
# (which hops channels itself), and re-renders scan_render_table roughly
# once per second until any key is pressed, then restores managed mode.
# Universal — used by the live clone picker and the standalone --scan-aps
# survey; any future feature that wants a live nearby-AP view can call
# this directly. Populates SCAN_AP_INFO; callers should call
# scan_build_sorted_table afterward to consume the result.
scan_run_live() {
    local iface="$1"
    local header="${2:-Live AP scan — press any key to stop}"

    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; cannot run a live scan."
        return 1
    }

    log "Switching ${iface} to monitor mode for live scan..."
    _scan_enter_monitor_mode "${iface}" || return 1

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
        if read -r -t 0.2 -n 1 -s key; then
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
    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; cannot scan for nearby access points."
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
    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; falling back to standard clone selection."
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
