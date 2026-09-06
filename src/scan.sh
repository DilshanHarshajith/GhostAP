#!/bin/bash

# AP scanning
# ------------------------------------------------------------------
# All over-the-air AP discovery lives here: enter/exit monitor mode,
# airodump-ng CSV capture, and the BSSID/SSID/channel/security/signal
# data that scan consumers (clone discovery, the standalone --scan-aps
# survey) consume. airodump-ng owns channel hopping itself via the -c
# flag, so there is no separate hopper process to manage.
#
# The functions below are split into two layers:
#   - scan_* / _scan_*   Universal primitives. No knowledge of cloning,
#                         hostapd, or any particular feature. Usable
#                         anywhere GhostAP needs to know what access
#                         points are nearby (clone target discovery,
#                         the standalone AP survey via --scan-aps, or
#                         any future feature that needs the same data).
#   - configure_clone_*  Feature-specific consumers that call the
#                         universal primitives and apply the result to
#                         DEFAULTS for cloning.
#
# Lifecycle invariants:
#   - Every function that takes the interface to monitor mode registers
#     an EXIT trap so the radio is always restored to managed mode and
#     the airodump-ng child is always killed — even on Ctrl-C, SIGTERM,
#     or an internal error. The trap is reset before returning cleanly
#     so a follow-up scan can install its own.
#   - The SCAN_AP_INFO map is populated incrementally across calls to
#     _scan_refresh_data; airodump's CSV grows over the scan window and
#     we tail it from the last byte consumed.
#   - Signal is a running MAX (strongest seen) per BSSID across the
#     scan window. APs that disappear from the CSV stay in the map
#     until the next scan overwrites — that matches user expectations
#     during a live table render and makes the strongest-signal clone
#     pick stable.
#
# Only use against networks/devices you own or are explicitly
# authorized to test.

# ------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------

# PID of the running airodump-ng, if any. Cleared on _scan_stop_capture.
declare -g SCAN_AIRODUMP_PID=""

# Path to the airodump-ng CSV output (a `<prefix>-01.csv` next to a
# `<prefix>-01.cap` we don't keep). Re-generated per scan so two
# consecutive scans cannot read each other's stale data.
declare -g SCAN_CSV_PREFIX=""

# Byte offset into SCAN_CSV_PREFIX-01.csv consumed by _scan_refresh_data
# on the previous tick. Lets the next tick read only the appended bytes
# instead of re-parsing the whole growing CSV every second.
declare -g SCAN_CSV_BYTES_READ=0

# Default duration (seconds) for the non-live "quick" scans used by
# the plain interactive picker and explicit --clone "SSID" resolution.
# These need monitor mode + a capture window (unlike the old instant
# iwlist scan), so keep it short but long enough to reliably catch a
# beacon across multiple channel hops.
declare -g CLONE_QUICK_SCAN_DURATION=10

# BSSID -> "ssid|channel|security|signal" (from the live CSV).
# Populated by _scan_refresh_data; consumed by scan_build_sorted_table.
declare -g -A SCAN_AP_INFO

# Sorted "bssid|ssid|channel|security|signal" rows, built on demand
# from SCAN_AP_INFO via scan_build_sorted_table. Strongest signal first.
declare -g -a SCAN_AP_TABLE=()

# A scan-sentinel value: dBm "unknown" sorts numerically below every
# real signal. Display keeps "N/A"; sorting uses this.
declare -g SCAN_SIGNAL_UNKNOWN=-200

# ============================================================
# Universal scanning primitives
# ============================================================

# Channel set for airodump-ng's -c flag. 2.4GHz 1-11 always; append
# 5GHz UNII-1 (36,40,44,48) only if the radio advertises 5GHz support
# (`iw phy` reports the 5180 MHz band). DFS channels are intentionally
# excluded — they need CAC and won't help clone discovery.
_scan_channels() {
    local chans=(1 2 3 4 5 6 7 8 9 10 11)
    if iw phy 2>/dev/null | grep -q "5180 MHz"; then
        chans+=(36 40 44 48)
    fi
    local IFS=,
    printf '%s' "${chans[*]}"
}

# Switch `iface` into monitor mode. Best-effort: NetworkManager is told
# to leave the interface alone (when available), then we toggle the
# link down, set the type, and bring it back up. Returns 0 on success.
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

# Switch `iface` back to managed mode. Idempotent and best-effort:
# every step swallows errors because cleanup paths call this even
# when the interface is already in a usable state.
_scan_exit_monitor_mode() {
    local iface="$1"
    [[ -n "${iface}" ]] || return 0
    ip link set "${iface}" down 2>/dev/null || true
    iw dev "${iface}" set type managed 2>/dev/null || true
    ip link set "${iface}" up 2>/dev/null || true
    if command -v nmcli >/dev/null; then
        nmcli device set "${iface}" managed yes 2>/dev/null || true
    fi
}

# Launch airodump-ng in CSV output mode against `iface`, hopping
# across the channel set from _scan_channels. The capture prefix is
# unique per scan session so two consecutive scans cannot read each
# other's stale CSV (or get file-rotation rollover).
#
# Globals set: SCAN_AIRODUMP_PID, SCAN_CSV_PREFIX, SCAN_CSV_BYTES_READ.
# Returns 0 on success, 1 on airodump-ng failure to start.
_scan_start_capture() {
    local iface="$1"

    # Fresh, unique prefix per scan session. `airodump-ng --write X`
    # writes X-01.csv (and X-01.cap, which we don't keep).
    SCAN_CSV_PREFIX="${TMP_DIR}/scan_airodump_$$_$(date +%s%N)"
    SCAN_CSV_BYTES_READ=0

    local chanlist
    chanlist="$(_scan_channels)"

    airodump-ng --write "${SCAN_CSV_PREFIX}" --output-format csv \
        -c "${chanlist}" "${iface}" \
        >> "${AIRODUMP_LOG}" 2>&1 &
    SCAN_AIRODUMP_PID=$!

    # Give airodump a moment to start, then verify it is actually
    # running. If it isn't, log to the airodump log and bail.
    sleep 1
    if ! kill -0 "${SCAN_AIRODUMP_PID}" 2>/dev/null; then
        warn "airodump-ng failed to start for AP scan capture. Check ${AIRODUMP_LOG}"
        SCAN_AIRODUMP_PID=""
        SCAN_CSV_PREFIX=""
        return 1
    fi

    # airodump-ng writes the CSV file as soon as it has the link layer
    # up. Wait for it to appear so callers can poll _scan_refresh_data
    # without a race; bounded so an absent file still surfaces.
    local waited=0
    while [[ ! -s "${SCAN_CSV_PREFIX}-01.csv" ]] && (( waited < 5 )); do
        sleep 1
        ((waited++))
    done

    return 0
}

# Stop the running airodump-ng and clean up its on-disk artifacts.
# Idempotent: safe to call twice or before _scan_start_capture.
# Globals cleared: SCAN_AIRODUMP_PID, SCAN_CSV_PREFIX,
# SCAN_CSV_BYTES_READ.
_scan_stop_capture() {
    if [[ -n "${SCAN_AIRODUMP_PID}" ]]; then
        kill "${SCAN_AIRODUMP_PID}" 2>/dev/null
        # Wait briefly for clean exit, then SIGKILL if airodump-ng
        # ignored SIGTERM (rare, but seen on heavily-loaded systems).
        local i
        for i in 1 2 3 4 5; do
            kill -0 "${SCAN_AIRODUMP_PID}" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "${SCAN_AIRODUMP_PID}" 2>/dev/null; then
            kill -9 "${SCAN_AIRODUMP_PID}" 2>/dev/null || true
        fi
        wait "${SCAN_AIRODUMP_PID}" 2>/dev/null
    fi
    SCAN_AIRODUMP_PID=""

    if [[ -n "${SCAN_CSV_PREFIX}" ]]; then
        # Clean the CSV *and* the sidecar .cap that airodump writes
        # next to it. Both share the prefix glob, so one rm handles
        # any rotation variants too.
        rm -f "${SCAN_CSV_PREFIX}"-* 2>/dev/null
        SCAN_CSV_PREFIX=""
    fi
    SCAN_CSV_BYTES_READ=0
}

# Read only the bytes appended to the CSV since the last refresh and
# merge them into SCAN_AP_INFO. Per-BSSID signal is a running MAX
# (strongest seen), so the live table shows the best signal we have
# for each BSSID across the whole scan window.
#
# Idempotent: calling with no new bytes is a no-op.
_scan_refresh_data() {
    local csv_file="${SCAN_CSV_PREFIX}-01.csv"
    [[ -s "${csv_file}" ]] || return 0

    local current_size
    current_size=$(stat -c '%s' "${csv_file}" 2>/dev/null || echo 0)
    (( current_size > SCAN_CSV_BYTES_READ )) || return 0

    # Read only the appended bytes. tail -c +N is 1-indexed and reads
    # from byte N to EOF; add 1 to skip the byte we already consumed.
    local new_bytes
    new_bytes=$(tail -c "+$((SCAN_CSV_BYTES_READ + 1))" "${csv_file}" 2>/dev/null) || return 0
    SCAN_CSV_BYTES_READ=${current_size}

    # The new bytes can include a partial last line (mid-flush) or a
    # complete AP block write — both fine for awk. We pipe the bytes
    # into awk directly instead of touching /dev/stdin to keep
    # behavior portable across bash versions where `[[ -s ]]` on a
    # pipe can be unreliable.
    local parsed=""
    parsed=$(printf '%s' "${new_bytes}" | awk -F', ' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function is_bssid(s) {
            return s ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/
        }
        { sub(/\r$/, "") }
        /^BSSID/        { in_ap = 1; next }
        /^Station MAC/  { in_ap = 0 }
        in_ap && !NF    { in_ap = 0 }
        in_ap && NF >= 14 {
            bssid = trim($1)
            if (!is_bssid(bssid)) next
            channel = trim($4)
            privacy = trim($6)
            auth    = trim($8)
            power   = trim($9)
            essid   = trim($14)
            printf "%s\037%s\037%s\037%s\037%s\037%s\n", \
                bssid, essid, channel, privacy, auth, power
        }
    ') || parsed=""

    while IFS=$'\037' read -r bssid essid channel privacy auth power; do
        [[ -z "${bssid}" ]] && continue
        [[ "${#bssid}" -ne 17 ]] && continue

        # SSID: airodump-ng gives plain text; just strip CR/LF and
        # surrounding whitespace. An empty essid (a hidden network)
        # is dropped here so it never reaches the live table.
        local ssid="${essid//[$'\r\n']/}"
        ssid="${ssid#"${ssid%%[![:space:]]*}"}"
        ssid="${ssid%"${ssid##*[![:space:]]}"}"
        [[ -z "${ssid}" ]] && continue

        local security
        security="$(_scan_classify_security "${privacy}" "${auth}")"

        # Running-max signal. airodump-ng rewrites the same BSSID row
        # on every beacon update; we want the strongest power seen
        # across the whole scan window. New BSSIDs (or ones whose
        # current entry is N/A) just take the new value.
        if [[ -n "${SCAN_AP_INFO[${bssid}]:-}" ]]; then
            IFS='|' read -r _ _ _ prev_signal <<< "${SCAN_AP_INFO[${bssid}]}"
            if [[ "${prev_signal}" == "N/A" || "${power}" == "N/A" ]]; then
                : # keep prev signal if we already have a real value
            elif (( power > prev_signal )); then
                : # power is already stronger; fall through to write
            else
                continue
            fi
        fi

        SCAN_AP_INFO["${bssid}"]="${ssid}|${channel:-?}|${security}|${power:-N/A}"
    done <<< "${parsed}"
}

# Classify airodump-ng's Privacy + Authentication columns into
# open / wpa2 / wpa3. GhostAP only needs this granularity for cloning
# (hostapd config differs by security mode). OWE / SAE / WPA3-
# transitional all collapse into wpa3 since airodump-ng doesn't
# reliably expose the distinction in these two columns.
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

    # SAE (WPA3-Personal) is exposed in Authentication; airodump also
    # marks transitional/WPA3 networks directly in Privacy
    # (e.g. "WPA2WPA3", "WPA3").
    if [[ "${a}" == *"SAE"* || "${p}" == *"WPA3"* ]]; then
        printf 'wpa3'
        return 0
    fi

    # WEP / WPA / WPA2 / enterprise all map to wpa2 here — same
    # classification as the original tshark patch, which only had
    # open/wpa2/wpa3 granularity.
    printf 'wpa2'
}

# Build SCAN_AP_TABLE from SCAN_AP_INFO, sorted by signal strength
# (strongest first). Unknown signals sort to the bottom via the
# SCAN_SIGNAL_UNKNOWN sentinel; the displayed value stays "N/A".
scan_build_sorted_table() {
    SCAN_AP_TABLE=()
    (( ${#SCAN_AP_INFO[@]} > 0 )) || return 0

    local bssid ssid channel security signal sort_key
    for bssid in "${!SCAN_AP_INFO[@]}"; do
        IFS='|' read -r ssid channel security signal <<< "${SCAN_AP_INFO[${bssid}]}"
        if [[ "${signal}" == "N/A" || ! "${signal}" =~ ^-?[0-9]+$ ]]; then
            sort_key="${SCAN_SIGNAL_UNKNOWN}"
        else
            sort_key="${signal}"
        fi
        # Prefix with sort_key so the sort is purely numeric and N/A
        # sinks to the bottom regardless of locale.
        SCAN_AP_TABLE+=("${sort_key}|${bssid}|${ssid}|${channel}|${security}|${signal}")
    done

    mapfile -t SCAN_AP_TABLE < <(
        printf '%s\n' "${SCAN_AP_TABLE[@]}" \
            | LC_ALL=C sort -t'|' -k1,1nr \
            | cut -d'|' -f2-
    )
}

# Convert SCAN_AP_TABLE rows into "SSID | BSSID | chN | SEC | dBm"
# labels suitable for select_from_list(). Shared by every picker
# that presents scan results to the user.
scan_table_to_labels() {
    local entry bssid ssid channel security signal
    for entry in "${SCAN_AP_TABLE[@]}"; do
        IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
        printf '%s\n' "${ssid:-<hidden>} | ${bssid} | ch${channel} | ${security} | ${signal}dBm"
    done
}

# Inverse of scan_table_to_labels: given a label, echo the matching
# SCAN_AP_TABLE row. Returns 1 if no match (shouldn't happen if the
# label came from the same table, but guards against truncation).
scan_table_row_for_label() {
    local target_label="$1"
    local entry bssid ssid channel security signal label
    for entry in "${SCAN_AP_TABLE[@]}"; do
        IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
        label="${ssid:-<hidden>} | ${bssid} | ch${channel} | ${security} | ${signal}dBm"
        if [[ "${label}" == "${target_label}" ]]; then
            printf '%s\n' "${entry}"
            return 0
        fi
    done
    return 1
}

# Render the live table to stderr. Used by scan_run_live every refresh
# and by scan_show_nearby_aps to print the final result.
scan_render_table() {
    local header="${1:-Nearby access points}"

    tput cup 0 0 2>/dev/null || true
    tput ed 2>/dev/null || true

    {
        echo "${header}"
        echo
        printf "%-18s %-32s %-4s %-8s %-8s\n" "BSSID" "SSID" "CH" "SEC" "SIGNAL"
        printf '%s\n' "----------------------------------------------------------------"

        if (( ${#SCAN_AP_INFO[@]} == 0 )); then
            echo "(no beacons captured yet...)"
        else
            local bssid ssid channel security signal sort_key
            for bssid in "${!SCAN_AP_INFO[@]}"; do
                IFS='|' read -r ssid channel security signal <<< "${SCAN_AP_INFO[${bssid}]}"
                if [[ "${signal}" == "N/A" || ! "${signal}" =~ ^-?[0-9]+$ ]]; then
                    sort_key="${SCAN_SIGNAL_UNKNOWN}"
                else
                    sort_key="${signal}"
                fi
                printf "%s\t%s|%s|%s|%s|%s\n" "${sort_key}" "${bssid}" "${ssid}" "${channel}" "${security}" "${signal}"
            done \
                | LC_ALL=C sort -t$'\t' -k1,1nr \
                | cut -f2- \
                | while IFS='|' read -r bssid ssid channel security signal; do
                    printf "%-18s %-32s %-4s %-8s %-8s\n" "${bssid}" "${ssid:-<hidden>}" "${channel}" "${security}" "${signal}"
                done
        fi
    } >&2
}

# Run airodump-ng for `duration` seconds with no live rendering,
# then restore managed mode. Populates SCAN_AP_INFO on success.
# Universal: used by the quick interactive clone picker, explicit
# --clone "SSID" resolution, and the standalone --scan-aps survey.
scan_run_background() {
    local iface="$1"
    local duration="$2"

    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; cannot run a scan."
        return 1
    }

    # Take ownership of teardown: any exit from this function (normal,
    # error, or signal) restores the radio and kills airodump-ng.
    _scan_install_exit_traps "${iface}"
    # shellcheck disable=SC2064  # we want iface captured at install time
    trap "_scan_stop_capture; _scan_exit_monitor_mode '${iface}'; exit 130" INT TERM

    _scan_enter_monitor_mode "${iface}" || {
        _scan_stop_capture
        _scan_exit_monitor_mode "${iface}"
        _scan_clear_exit_traps
        return 1
    }

    if ! _scan_start_capture "${iface}"; then
        _scan_stop_capture
        _scan_exit_monitor_mode "${iface}"
        _scan_clear_exit_traps
        return 1
    fi

    local elapsed=0
    while (( elapsed < duration )); do
        sleep 1
        ((elapsed++))
    done
    _scan_refresh_data

    _scan_stop_capture
    _scan_exit_monitor_mode "${iface}"
    _scan_clear_exit_traps
    log "Restored ${iface} to managed mode."
    return 0
}

# Live, continuously-updating scan: enters monitor mode, runs
# airodump-ng (which hops channels itself), and re-renders the table
# roughly once per second until any key is pressed, then restores
# managed mode. Universal — used by the live clone picker and the
# standalone --scan-aps survey. Populates SCAN_AP_INFO; callers
# should call scan_build_sorted_table afterward.
scan_run_live() {
    local iface="$1"
    local header="${2:-Live AP scan — press any key to stop}"

    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; cannot run a live scan."
        return 1
    }

    _scan_install_exit_traps "${iface}"
    # shellcheck disable=SC2064
    trap "_scan_stop_capture; _scan_exit_monitor_mode '${iface}'; exit 130" INT TERM

    log "Switching ${iface} to monitor mode for live scan..."
    _scan_enter_monitor_mode "${iface}" || {
        _scan_stop_capture
        _scan_exit_monitor_mode "${iface}"
        _scan_clear_exit_traps
        return 1
    }

    if ! _scan_start_capture "${iface}"; then
        _scan_stop_capture
        _scan_exit_monitor_mode "${iface}"
        _scan_clear_exit_traps
        return 1
    fi

    clear >&2
    local key=""
    while true; do
        _scan_refresh_data
        scan_render_table "${header}"
        # 1s is the refresh interval AND the keypress poll — read
        # returns early on any key, so worst-case latency is 1s.
        if read -r -t 1 -n 1 -s key; then
            break
        fi
    done

    _scan_stop_capture
    _scan_exit_monitor_mode "${iface}"
    _scan_clear_exit_traps
    clear >&2
    log "Restored ${iface} to managed mode."
    return 0
}

# Standalone AP survey: scans and prints a snapshot of nearby access
# points, then returns — no cloning, no AP setup. Triggered by
# --scan-aps [SECONDS] in config.sh.
scan_show_nearby_aps() {
    [[ "${DEFAULTS[ETHERNET_MODE]}" != true ]] || {
        warn "Ethernet AP mode has no radio to scan with."
        return 1
    }
    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; cannot scan for nearby access points."
        return 1
    }

    local iface="${DEFAULTS[INTERFACE]}"
    [[ -n "${iface}" ]] || {
        warn "No interface available for scanning."
        return 1
    }

    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        scan_run_live "${iface}" "Live AP scan — press any key to stop" || return 1
    else
        local duration="${SCAN_APS_DURATION:-15}"
        log "Scanning for nearby access points (${duration}s)..."
        scan_run_background "${iface}" "${duration}" || return 1
    fi

    scan_build_sorted_table
    if (( ${#SCAN_AP_TABLE[@]} == 0 )); then
        warn "No nearby access points found."
        return 1
    fi

    # Reuse scan_render_table for the final layout so the look matches
    # the live view; the function writes to stderr which is the right
    # place for user-facing output from a CLI scan.
    scan_render_table "Found ${#SCAN_AP_TABLE[@]} access point(s)"
    return 0
}

# ------------------------------------------------------------------
# EXIT-trap helpers
# ------------------------------------------------------------------
# A separate EXIT trap guarantees teardown even on a normal return
# that still leaves airodump running (e.g. an error path that
# doesn't `return 1` after airodump is up). The function-level
# `trap` for INT/TERM chains into the same _scan_finish helper.

# Save any pre-existing EXIT/INT/TERM traps so the scan functions
# can restore them when they return cleanly (a follow-up scan
# shouldn't inherit ours).
declare -g _SCAN_PREV_EXIT_TRAP=""
declare -g _SCAN_PREV_INT_TRAP=""
declare -g _SCAN_PREV_TERM_TRAP=""

_scan_install_exit_traps() {
    local iface="$1"
    _SCAN_PREV_EXIT_TRAP=$(trap -p EXIT | sed -e "s/^trap -- '//" -e "s/'$//")
    _SCAN_PREV_INT_TRAP=$(trap -p INT | sed -e "s/^trap -- '//" -e "s/'$//")
    _SCAN_PREV_TERM_TRAP=$(trap -p TERM | sed -e "s/^trap -- '//" -e "s/'$//")
    # shellcheck disable=SC2064
    trap "_scan_finish '${iface}'" EXIT
}

_scan_clear_exit_traps() {
    if [[ -n "${_SCAN_PREV_EXIT_TRAP}" ]]; then
        # shellcheck disable=SC2064
        trap "${_SCAN_PREV_EXIT_TRAP}" EXIT
    else
        trap - EXIT
    fi
    trap - INT TERM
    _SCAN_PREV_EXIT_TRAP=""
    _SCAN_PREV_INT_TRAP=""
    _SCAN_PREV_TERM_TRAP=""
}

# Final teardown: stop airodump and restore managed mode. Called
# from the EXIT trap (and from INT/TERM). Idempotent.
_scan_finish() {
    local iface="$1"
    _scan_stop_capture
    _scan_exit_monitor_mode "${iface}"
}

# ============================================================
# Clone-specific consumers
# ============================================================
# Everything below applies scan results to DEFAULTS for cloning.

# Apply a resolved (ssid, channel, mac, security) tuple to DEFAULTS,
# honoring any values the user already gave explicitly via CLI
# (--ssid, --channel, --mac, --security) and warning if a WPA
# password is still needed. Used by every clone-resolution path so
# behavior — including respecting explicit overrides — stays
# consistent regardless of how the target AP was found.
_scan_apply_clone_selection() {
    local ssid="$1" channel="$2" mac="$3" security="$4"

    DEFAULTS[CLONE_SSID]="${ssid}"

    if [[ -z "${ARG[SSID]:-}" ]]; then
        DEFAULTS[SSID]="${ssid}"
    else
        log "Preserving specified SSID: ${DEFAULTS[SSID]} (ignoring clone SSID: ${ssid})"
    fi

    if [[ -z "${ARG[CHANNEL]:-}" ]]; then
        DEFAULTS[CHANNEL]="${channel}"
    else
        log "Preserving specified Channel: ${DEFAULTS[CHANNEL]} (ignoring clone Channel: ${channel})"
    fi

    if [[ -z "${ARG[MAC]:-}" ]]; then
        DEFAULTS[MAC]="${mac}"
    else
        log "Preserving specified MAC: ${DEFAULTS[MAC]} (ignoring clone MAC: ${mac})"
    fi

    if [[ -z "${ARG[SECURITY]:-}" ]]; then
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

# Interactive live-scan clone picker: shows a continuously updating
# table of nearby APs until any key is pressed, then lets the user
# pick one.
configure_clone_live_scan() {
    [[ "${DEFAULTS[ETHERNET_MODE]}" != true ]] || return 1
    command -v airodump-ng >/dev/null || {
        warn "airodump-ng not installed; falling back to standard clone selection."
        return 1
    }

    local iface="${DEFAULTS[INTERFACE]}"
    scan_run_live "${iface}" "Live AP scan — press any key to stop and select a target to clone" || return 1

    scan_build_sorted_table
    (( ${#SCAN_AP_TABLE[@]} > 0 )) || { warn "No APs captured during scan."; return 1; }

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

# Default interactive clone-target picker: runs a short, non-live
# scan and presents a plain selection list. Replaces the old
# iwlist-based get_wifi_ssids()/get_ap_info() flow — every clone
# path now shares one accurate source of AP info (real signal, real
# WPA2-vs-WPA3 classification, exact BSSID).
configure_clone_quick_scan() {
    [[ "${DEFAULTS[ETHERNET_MODE]}" != true ]] || return 1

    local iface="${DEFAULTS[INTERFACE]}"
    log "Scanning for nearby access points (${CLONE_QUICK_SCAN_DURATION}s)..."
    scan_run_background "${iface}" "${CLONE_QUICK_SCAN_DURATION}" || return 1

    scan_build_sorted_table
    (( ${#SCAN_AP_TABLE[@]} > 0 )) || { warn "No nearby access points found."; return 1; }

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
# config) to full AP details via a short scan. If multiple nearby
# APs share the SSID, the strongest-signal match is used and the
# ambiguity is logged rather than silently picking one.
configure_clone_resolve_target() {
    local target_ssid="$1"
    [[ "${DEFAULTS[ETHERNET_MODE]}" != true ]] || return 1

    local iface="${DEFAULTS[INTERFACE]}"
    log "Scanning for '${target_ssid}' (${CLONE_QUICK_SCAN_DURATION}s)..."
    scan_run_background "${iface}" "${CLONE_QUICK_SCAN_DURATION}" || return 1

    scan_build_sorted_table
    (( ${#SCAN_AP_TABLE[@]} > 0 )) || return 1

    local -a matches=()
    local entry bssid ssid channel security signal
    for entry in "${SCAN_AP_TABLE[@]}"; do
        IFS='|' read -r bssid ssid channel security signal <<< "${entry}"
        [[ "${ssid}" == "${target_ssid}" ]] && matches+=("${entry}")
    done

    (( ${#matches[@]} > 0 )) || return 1

    if (( ${#matches[@]} > 1 )); then
        local first_bssid
        first_bssid="$(cut -d'|' -f1 <<< "${matches[0]}")"
        warn "Multiple access points broadcasting SSID '${target_ssid}' were found (${#matches[@]} matches)."
        warn "Using the strongest-signal match: BSSID ${first_bssid}. Use the interactive live scan (--int --clone) to pick a specific one instead."
    fi

    # matches[] preserves SCAN_AP_TABLE's sort order (signal desc),
    # so the first match is the best candidate.
    IFS='|' read -r bssid ssid channel security signal <<< "${matches[0]}"

    _scan_apply_clone_selection "${ssid}" "${channel}" "${bssid}" "${security}"
    return 0
}
