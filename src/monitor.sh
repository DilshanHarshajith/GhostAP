#!/bin/bash

# Connected-client monitoring for the operator's own GhostAP access point
# ------------------------------------------------------------------
# Tracks the devices connected to the GhostAP AP that is *running* — the
# clients associated to our hostapd, holding leases from our dnsmasq, or
# visible in our ARP table. This is deliberately NOT the airodump-ng /
# monitor-mode scan path (that discovers APs and their stations over the
# air); those primitives live in scan.sh and are never touched here,
# because putting the AP interface into monitor mode would kill the
# running access point.
#
# Three data sources are merged every tick, all keyed by lowercase
# colon MAC:
#   - hostapd_cli all_sta (or iw dev <iface> station dump fallback)
#       → signal, connected time, rx/tx byte counters (radio presence)
#   - ${TMP_DIR}/dhcp.leases (dnsmasq) → IP, hostname
#   - ip neigh show dev <iface>       → ARP reachability (online/offline)
#
# A client is "armed" (actively connected) when it is present on the
# radio, or — in ethernet AP mode / when no radio source exists — when
# it holds a lease or an ARP entry. A tracked client that stops being
# armed is given a short grace window (MON_OFFLINE_THRESHOLD ticks,
# default 3) with a background ping to refresh ARP before it is declared
# gone and removed from the dashboard. This fixes the old stale-lease
# problem: a device that leaves without sending DHCPRELEASE used to be
# listed as connected forever.
#
# The renderer redraws the table in place on stderr (like
# scan_render_table) so the dashboard overwrites itself instead of
# scrolling. When stderr is not a terminal, no table is printed —
# joins/leaves are still logged via log().
#
# Only use against networks/devices you own or are explicitly
# authorized to test.

# ------------------------------------------------------------------
# State (beyond the globals declared in globals.sh)
# ------------------------------------------------------------------

# MACs sighted exactly once that are waiting for a confirming tick
# before being promoted to "joined". Prevents join-spam from
# one-tick blips.
declare -g -A MON_PENDING=()

# How many join/leave events the live table keeps in its strip.
declare -g MONITOR_EVENTS_MAX=5

# ============================================================
# Data fetchers
# ============================================================

# Lowercase a MAC (both `iw` and `ip neigh` output can vary in case).
_mon_norm_mac() {
    printf '%s' "${1,,}"
}

# Fetch associated stations from hostapd_cli (preferred) or iw.
# Populates MON_STA[mac]="signal|connected_time|rx|tx" and sets
# MON_RADIO_SOURCE to "hostapd" | "iw" | "".
# Best-effort: never returns nonzero — the caller degrades to
# leases+ARP when no radio source is available.
_mon_fetch_stations() {
    local iface="$1"
    MON_STA=()
    MON_RADIO_SOURCE=""

    # Preferred: hostapd's control socket. Only useful if the hostapd
    # config sets ctrl_interface (our generated config does not), so
    # bound the connect with a short timeout and fall through to iw.
    if command -v hostapd_cli >/dev/null 2>&1; then
        local raw
        raw=$(hostapd_cli -t 2 -i "${iface}" all_sta 2>/dev/null)
        if [[ -z "${raw}" ]]; then
            raw=$(hostapd_cli -t 2 -p /var/run/hostapd -i "${iface}" all_sta 2>/dev/null)
        fi
        if [[ -n "${raw}" && "${raw}" != *"FAIL"* ]]; then
            MON_RADIO_SOURCE="hostapd"
            _mon_parse_hostapd_sta "${raw}"
            return 0
        fi
    fi

    # Fallback: query the kernel directly — works whenever the
    # interface is an AP, no control socket required.
    if command -v iw >/dev/null 2>&1; then
        local iw_raw
        iw_raw=$(iw dev "${iface}" station dump 2>/dev/null)
        if [[ -n "${iw_raw}" ]]; then
            MON_RADIO_SOURCE="iw"
            _mon_parse_iw_sta "${iw_raw}"
            return 0
        fi
    fi

    return 0
}

# Parse hostapd_cli all_sta output. Format:
#   aa:bb:cc:dd:ee:ff
#       signal=4521
#       connected_time=321
#       rx_bytes=1234
#       tx_bytes=5678
#       ...
# Tolerates missing keys; signal is normalized to dBm-ish (hostapd can
# report either raw dBm or 0.1 dBm units depending on kernel — |v|>200
# is treated as 0.1 dBm and divided by ten).
_mon_parse_hostapd_sta() {
    local raw="$1"
    local mac="" signal="" ctime="" rxb="" txb=""
    local line val
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        if [[ "${line}" =~ ^[[:space:]]*([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
            # End of previous record — store it.
            [[ -n "${mac}" ]] && MON_STA["${mac,,}"]="${signal}|${ctime}|${rxb}|${txb}"
            mac="${line//[[:space:]]/}"
            signal="" ctime="" rxb="" txb=""
        elif [[ -n "${mac}" ]]; then
            case "${line}" in
                *"signal="*)
                    val="${line##*=}"; val="${val//[[:space:]]/}"
                    if [[ "${val}" =~ ^-?[0-9]+$ ]]; then
                        if (( val > 200 || val < -200 )); then val=$(( val / 10 )); fi
                        signal="${val}"
                    fi
                    ;;
                *"connected_time="*)
                    ctime="${line##*=}"; ctime="${ctime//[[:space:]]/}"
                    [[ "${ctime}" =~ ^[0-9]+$ ]] || ctime=""
                    ;;
                *"rx_bytes="*) rxb="${line##*=}"; rxb="${rxb//[[:space:]]/}" ;;
                *"tx_bytes="*) txb="${line##*=}"; txb="${txb//[[:space:]]/}" ;;
            esac
        fi
    done <<< "${raw}"
    [[ -n "${mac}" ]] && MON_STA["${mac,,}"]="${signal}|${ctime}|${rxb}|${txb}"
}

# Parse `iw dev <iface> station dump` output. Format:
#   Station aa:bb:cc:dd:ee:ff (on wlan0)
#       inactive time:  123 ms
#       rx bytes:       1234
#       tx bytes:       5678
#       signal:         -42 dBm
#       connected time: 123 seconds
#       ...
_mon_parse_iw_sta() {
    local raw="$1"
    local mac="" signal="" ctime="" rxb="" txb=""
    local line val
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        if [[ "${line}" =~ ^Station[[:space:]]+([0-9A-Fa-f:]+) ]]; then
            [[ -n "${mac}" ]] && MON_STA["${mac,,}"]="${signal}|${ctime}|${rxb}|${txb}"
            mac="${BASH_REMATCH[1]}"
            signal="" ctime="" rxb="" txb=""
        elif [[ -n "${mac}" ]]; then
            # NOTE: match "signal:" exactly — "signal avg:" must not.
            case "${line}" in
                *"signal:"*)
                    val="${line#*signal:}"
                    val="${val//[^0-9-]/}"
                    [[ "${val}" =~ ^-?[0-9]+$ ]] && signal="${val}"
                    ;;
                *"connected time:"*)
                    val="${line#*connected time:}"
                    val="${val//[^0-9]/}"
                    [[ "${val}" =~ ^[0-9]+$ ]] && ctime="${val}"
                    ;;
                *"rx bytes:"*) val="${line#*rx bytes:}"; rxb="${val//[^0-9]/}" ;;
                *"tx bytes:"*) val="${line#*tx bytes:}"; txb="${val//[^0-9]/}" ;;
            esac
        fi
    done <<< "${raw}"
    [[ -n "${mac}" ]] && MON_STA["${mac,,}"]="${signal}|${ctime}|${rxb}|${txb}"
}

# Parse the dnsmasq lease file. Format per line:
#   <expiry> <mac> <ip> <hostname> <clientid>
# Hostname is '*' when the client never sent one.
# Populates MON_LEASE[mac]="ip|hostname" and MON_IP2MAC[ip]=mac.
_mon_fetch_leases() {
    local lease_file="${1:-${TMP_DIR}/dhcp.leases}"
    MON_LEASE=()
    MON_IP2MAC=()
    [[ -f "${lease_file}" ]] || return 0

    local expiry mac ip hostname mac_lc
    while read -r expiry mac ip hostname _; do
        [[ "${mac}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || continue
        mac_lc="${mac,,}"
        [[ "${hostname}" == "*" ]] && hostname=""
        MON_LEASE["${mac_lc}"]="${ip}|${hostname}"
        MON_IP2MAC["${ip}"]="${mac_lc}"
    done < "${lease_file}"
}

# Parse the ARP/neighbor table for clients on the AP interface.
# IPv4 entries only (client leases are IPv4; v6 ND neighbors aren't
# GhostAP clients). Populates:
#   MON_NEIGH[ip]="state"      MON_NEIGH_MAC[ip]=mac
_mon_fetch_neigh() {
    local iface="$1"
    MON_NEIGH=()
    MON_NEIGH_MAC=()
    [[ -n "${iface}" ]] || return 0

    local parsed
    parsed=$(ip neigh show dev "${iface}" 2>/dev/null | awk '
        $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            mac = ""; state = ""
            for (i = 2; i <= NF; i++) {
                if ($i == "lladdr" && i < NF) mac = $(i + 1)
                if ($i == "REACHABLE" || $i == "STALE" || $i == "DELAY" ||
                    $i == "PROBE" || $i == "FAILED" || $i == "PERMANENT" ||
                    $i == "NOARP") state = $i
            }
            printf "%s\037%s\037%s\n", $1, mac, state
        }
    ')
    while IFS=$'\037' read -r ip mac state; do
        [[ -n "${state}" ]] && MON_NEIGH["${ip}"]="${state}"
        [[ -n "${mac}" ]]  && MON_NEIGH_MAC["${ip}"]="${mac,,}"
    done <<< "${parsed}"
}

# Is an ip neigh state "online"? REACHABLE/DELAY/PROBE/STALE/PERMANENT
# all mean the kernel believes the neighbor is alive.
_mon_neigh_state_online() {
    local state="$1"
    case "${state}" in
        REACHABLE|DELAY|PROBE|STALE|PERMANENT) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# Merge + offline detection
# ============================================================

# Build the current evidence record for a MAC from this tick's maps.
# Format: ip|hostname|signal|connected_time|rx|tx (all fields present
# but possibly empty). IP comes from leases first, then ARP.
_mon_merge_record() {
    local mac="$1"
    local ip="" hostname="" signal="" ctime="" rxb="" txb=""

    IFS='|' read -r ip hostname <<< "${MON_LEASE[${mac}]:-|}"
    if [[ -z "${ip}" ]]; then
        local lookup
        for lookup in "${!MON_NEIGH_MAC[@]}"; do
            if [[ "${MON_NEIGH_MAC[${lookup}]}" == "${mac}" ]]; then
                ip="${lookup}"
                break
            fi
        done
    fi
    IFS='|' read -r signal ctime rxb txb <<< "${MON_STA[${mac}]:-|||}"

    printf '%s|%s|%s|%s|%s|%s' "${ip}" "${hostname}" "${signal}" "${ctime}" "${rxb}" "${txb}"
}

# Is a MAC "armed" (actively connected) this tick? True when it is on
# the radio, or when it has an online ARP entry. When no radio source is
# available at all (ethernet AP mode, or hostapd/iw both failed),
# presence via lease/ARP counts as armed so the dashboard still works.
_mon_armed() {
    local mac="$1"

    [[ -n "${MON_STA[${mac}]:-}" ]] && return 0

    local lookup
    for lookup in "${!MON_NEIGH_MAC[@]}"; do
        if [[ "${MON_NEIGH_MAC[${lookup}]}" == "${mac}" ]] &&
           _mon_neigh_state_online "${MON_NEIGH[${lookup}]}"; then
            return 0
        fi
    done

    if [[ "${DEFAULTS[ETHERNET_MODE]}" == true || -z "${MON_RADIO_SOURCE}" ]]; then
        return 0
    fi
    return 1
}

# Background-ping a MAC's IP to refresh the ARP cache for the next
# tick. Fire-and-forget: short timeout, exits on its own.
_mon_nudge_arp() {
    local mac="$1" ip=""
    IFS='|' read -r ip _ <<< "${MONITOR_CLIENTS[${mac}]:-|}"
    [[ -n "${ip}" ]] || return 0
    ( ping -c 1 -W 1 -I "${DEFAULTS[INTERFACE]}" "${ip}" &>/dev/null & )
}

# Append a join/leave/offline event to the ring buffer + the log.
_mon_event() {
    local kind="$1" mac="$2" record="${3:-}"
    local ip="" hostname="" signal=""
    IFS='|' read -r ip hostname signal _ <<< "${record}"

    local ts
    ts="$(date '+%H:%M:%S')"
    local who="${hostname:-${ip:-<no ip>}}"
    local line=""
    case "${kind}" in
        join)  line="${ts}  + ${mac} (${who})${signal:+, ${signal}dBm} joined" ;;
        leave) line="${ts}  - ${mac} (${who}) left" ;;
        *) return 0 ;;
    esac

    MONITOR_EVENTS+=("${line}")
    if (( ${#MONITOR_EVENTS[@]} > MONITOR_EVENTS_MAX )); then
        MONITOR_EVENTS=("${MONITOR_EVENTS[@]:$(( ${#MONITOR_EVENTS[@]} - MONITOR_EVENTS_MAX ))}")
    fi
    log "${line}"
}

# One full refresh: fetch all sources, then merge them into
# MONITOR_CLIENTS, emitting join/leave events and applying the offline
# grace window. Renders the live table when stderr is a terminal.
monitor_tick() {
    local iface="${DEFAULTS[INTERFACE]:-}"
    [[ -n "${iface}" ]] || return 0

    _mon_fetch_leases
    _mon_fetch_neigh "${iface}"
    if [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]]; then
        MON_RADIO_SOURCE=""
    else
        _mon_fetch_stations "${iface}"
    fi

    # Union of every MAC sighted this tick.
    local -A seen=()
    local mac ip
    for mac in "${!MON_STA[@]}"; do seen["${mac}"]=1; done
    for mac in "${!MON_LEASE[@]}"; do seen["${mac}"]=1; done
    for ip in "${!MON_NEIGH_MAC[@]}"; do seen["${MON_NEIGH_MAC[${ip}]}"]=1; done

    # Promote pending MACs (sighted last tick) into the client table.
    for mac in "${!seen[@]}"; do
        if [[ -n "${MONITOR_CLIENTS[${mac}]:-}" ]]; then
            continue
        fi
        if [[ -n "${MON_PENDING[${mac}]:-}" ]]; then
            unset MON_PENDING["${mac}"]
            MONITOR_CLIENTS["${mac}"]="$(_mon_merge_record "${mac}")|Online"
            MON_ARP_MISSES["${mac}"]=0
            _mon_event join "${mac}" "${MONITOR_CLIENTS[${mac}]}"
        else
            MON_PENDING["${mac}"]=1
        fi
    done
    # Drop pending sighted only once (transient).
    for mac in "${!MON_PENDING[@]}"; do
        [[ -n "${seen[${mac}]:-}" ]] || unset MON_PENDING["${mac}"]
    done

    # Update tracked clients: armed → Online; in grace → Leaving;
    # over threshold → leave + purge.
    local -A kept=()
    local rec misses
    for mac in "${!MONITOR_CLIENTS[@]}"; do
        rec="${MONITOR_CLIENTS[${mac}]}"

        if [[ -z "${seen[${mac}]:-}" ]]; then
            # Untracked this tick entirely (no lease, no ARP, no radio).
            misses=$(( ${MON_ARP_MISSES[${mac}]:-0} + 1 ))
            if (( misses >= MON_OFFLINE_THRESHOLD )); then
                _mon_event leave "${mac}" "${rec}"
                unset MONITOR_CLIENTS["${mac}"]
                unset MON_ARP_MISSES["${mac}"]
                continue
            fi
            MON_ARP_MISSES["${mac}"]=${misses}
            kept["${mac}"]="${rec%|*}|Leaving"
            continue
        fi

        if _mon_armed "${mac}"; then
            MON_ARP_MISSES["${mac}"]=0
            kept["${mac}"]="$(_mon_merge_record "${mac}")|Online"
            continue
        fi

        # Present but not armed (e.g. a stale lease after the client left).
        misses=$(( ${MON_ARP_MISSES[${mac}]:-0} + 1 ))
        MON_ARP_MISSES["${mac}"]=${misses}
        if (( misses >= MON_OFFLINE_THRESHOLD )); then
            _mon_event leave "${mac}" "${rec}"
            unset MONITOR_CLIENTS["${mac}"]
            unset MON_ARP_MISSES["${mac}"]
            continue
        fi
        _mon_nudge_arp "${mac}"
        kept["${mac}"]="$(_mon_merge_record "${mac}")|Leaving"
    done
    MONITOR_CLIENTS=()
    for mac in "${!kept[@]}"; do
        MONITOR_CLIENTS["${mac}"]="${kept[${mac}]}"
    done

    if [[ -t 2 ]]; then
        monitor_render_table
    fi
}

# ============================================================
# Rendering
# ============================================================

_mon_format_connected() {
    local secs="$1"
    [[ "${secs}" =~ ^[0-9]+$ ]] || { printf 'N/A'; return 0; }
    local h m s
    h=$(( secs / 3600 ))
    m=$(( (secs % 3600) / 60 ))
    s=$(( secs % 60 ))
    printf '%02d:%02d:%02d' "${h}" "${m}" "${s}"
}

_mon_format_bytes() {
    local b="${1:-0}"
    [[ "${b}" =~ ^[0-9]+$ ]] || { printf '0B'; return 0; }
    if (( b >= 1099511627776 )); then printf '%dT' $(( b / 1099511627776 ))
    elif (( b >= 1073741824 )); then printf '%dG' $(( b / 1073741824 ))
    elif (( b >= 1048576 )); then printf '%dM' $(( b / 1048576 ))
    elif (( b >= 1024 )); then printf '%dK' $(( b / 1024 ))
    else printf '%dB' "${b}"; fi
}

_mon_truncate() {
    local s="$1" max="$2"
    if (( ${#s} > max )); then
        printf '%s…' "${s:0:$(( max - 1 ))}"
    else
        printf '%s' "${s}"
    fi
}

# Build the display lines into a caller-named array. Rows are sorted by
# signal strength (unknown sinks to the bottom, reusing scan.sh's
# SCAN_SIGNAL_UNKNOWN sentinel and tab-prefix numeric-sort idiom).
_mon_build_lines() {
    local -n _out="$1"

    _out=()
    _out+=("GhostAP Live Monitor — ${DEFAULTS[INTERFACE]}  SSID:\"${DEFAULTS[SSID]:-}\"  CH:${DEFAULTS[CHANNEL]:-}  Clients:${#MONITOR_CLIENTS[@]}   $(date '+%H:%M:%S')")
    _out+=("--------------------------------------------------------------------------------")
    _out+=("MAC                IP                 Hostname          Signal    Connected     RX/TX        Status")
    _out+=("--------------------------------------------------------------------------------")

    if (( ${#MONITOR_CLIENTS[@]} == 0 )); then
        _out+=("(no clients connected)")
    else
        local -a raw_rows=()
        local mac rec ip hostname signal ctime rxb txb status key
        for mac in "${!MONITOR_CLIENTS[@]}"; do
            IFS='|' read -r ip hostname signal ctime rxb txb status <<< "${MONITOR_CLIENTS[${mac}]}"
            if [[ "${signal}" =~ ^-?[0-9]+$ ]]; then
                key="${signal}"
            else
                key="${SCAN_SIGNAL_UNKNOWN}"
            fi
            raw_rows+=("${key}|${mac}|${ip}|${hostname}|${signal}|${ctime}|${rxb}|${txb}|${status}")
        done

        local -a sorted
        mapfile -t sorted < <(
            printf '%s\n' "${raw_rows[@]}" \
                | LC_ALL=C sort -t'|' -k1,1nr \
                | cut -d'|' -f2-
        )

        local row h sig cn trx line
        for row in "${sorted[@]}"; do
            IFS='|' read -r mac ip hostname signal ctime rxb txb status <<< "${row}"
            [[ -n "${hostname}" ]] || hostname="Unknown"
            h="$(_mon_truncate "${hostname}" 15)"
            sig="${signal:-N/A}"
            [[ "${sig}" =~ ^-?[0-9]+$ ]] && sig="${sig}dBm"
            cn="$(_mon_format_connected "${ctime}")"
            trx="$(_mon_format_bytes "${rxb}")/$(_mon_format_bytes "${txb}")"
            printf -v line '%-17s %-15s %-15s %8s %9s %10s %-7s' \
                "${mac}" "${ip:-N/A}" "${h}" "${sig}" "${cn}" "${trx}" "${status:-Online}"
            _out+=("${line}")
        done
    fi

    if (( ${#MONITOR_EVENTS[@]} > 0 )); then
        _out+=("--------------------------------------------------------------------------------")
        local ev
        for ev in "${MONITOR_EVENTS[@]}"; do
            _out+=("${ev}")
        done
    fi
}

# Redraw the live client table in place on stderr (top of the screen).
# No-op when stderr is not a terminal — non-interactive runs just log
# join/leave events.
monitor_render_table() {
    local -a lines
    _mon_build_lines lines

    tput cup 0 0 >&2 2>/dev/null
    tput ed >&2 2>/dev/null
    printf '%s\n' "${lines[@]}" >&2
}

# One-shot, read-only snapshot of who is connected right now. Fetches
# all sources but does NOT mutate MONITOR_CLIENTS or fire events, so it
# is safe to call from the old show_connected_clients alias and from
# non-interactive contexts. Prints a plain table to stderr.
monitor_snapshot() {
    local iface="${DEFAULTS[INTERFACE]:-}"
    [[ -n "${iface}" ]] || { warn "No interface configured; cannot snapshot clients."; return 1; }

    _mon_fetch_leases
    _mon_fetch_neigh "${iface}"
    if [[ "${DEFAULTS[ETHERNET_MODE]}" == true ]]; then
        MON_RADIO_SOURCE=""
    else
        _mon_fetch_stations "${iface}"
    fi

    local -A seen=()
    local mac ip
    for mac in "${!MON_STA[@]}"; do seen["${mac}"]=1; done
    for mac in "${!MON_LEASE[@]}"; do seen["${mac}"]=1; done
    for ip in "${!MON_NEIGH_MAC[@]}"; do seen["${MON_NEIGH_MAC[${ip}]}"]=1; done

    local -a raw_rows=()
    local sig key rec
    for mac in "${!seen[@]}"; do
        rec="$(_mon_merge_record "${mac}")"
        IFS='|' read -r _ _ sig _ <<< "${rec}|x"
        if [[ "${sig}" =~ ^-?[0-9]+$ ]]; then
            key="${sig}"
        else
            key="${SCAN_SIGNAL_UNKNOWN}"
        fi
        raw_rows+=("${key}|${mac}|${rec}")
    done

    local -a sorted
    mapfile -t sorted < <(
        printf '%s\n' "${raw_rows[@]}" \
            | LC_ALL=C sort -t'|' -k1,1nr \
            | cut -d'|' -f2-
    )

    echo "Connected clients (snapshot) — ${iface}" >&2
    echo "--------------------------------------------------------------------------------" >&2
    echo "MAC                IP                 Hostname          Signal    Connected     RX/TX        Status" >&2
    echo "--------------------------------------------------------------------------------" >&2
    if (( ${#sorted[@]} == 0 )); then
        echo "(no clients connected)" >&2
    else
        local row h sig cn trx out status
        for row in "${sorted[@]}"; do
            IFS='|' read -r mac rec <<< "${row}"
            IFS='|' read -r ip hostname sig ctime rxb txb <<< "${rec}"
            status="Online"
            [[ -n "${hostname}" ]] || hostname="Unknown"
            h="$(_mon_truncate "${hostname}" 15)"
            [[ "${sig}" =~ ^-?[0-9]+$ ]] && sig="${sig}dBm" || sig="N/A"
            cn="$(_mon_format_connected "${ctime}")"
            trx="$(_mon_format_bytes "${rxb}")/$(_mon_format_bytes "${txb}")"
            printf -v out '%-17s %-15s %-15s %8s %9s %10s %-7s' \
                "${mac}" "${ip:-N/A}" "${h}" "${sig}" "${cn}" "${trx}" "${status}"
            echo "${out}" >&2
        done
    fi
    echo "--------------------------------------------------------------------------------" >&2
}

# ============================================================
# Interactive live loop (monitor_run_live)
# ============================================================
# Provided for a self-contained blocking client monitor (a future
# --monitor entry point, or manual use). The default main loop calls
# monitor_tick directly; this only adds key handling + cursor
# management on top of the same tick.

declare -g _MON_PREV_EXIT_TRAP=""

_monitor_install_traps() {
    _MON_PREV_EXIT_TRAP=$(trap -p EXIT | sed -e "s/^trap -- '//" -e "s/'$//")
    # shellcheck disable=SC2064
    trap "_monitor_finish" EXIT
}

_monitor_clear_traps() {
    if [[ -n "${_MON_PREV_EXIT_TRAP}" ]]; then
        # shellcheck disable=SC2064
        trap "${_MON_PREV_EXIT_TRAP}" EXIT
    else
        trap - EXIT
    fi
    _MON_PREV_EXIT_TRAP=""
}

_monitor_finish() {
    tput cnorm >&2 2>/dev/null
    tput sgr0 >&2 2>/dev/null
    clear >&2 2>/dev/null
}

# Blocking interactive client monitor: refreshes the table every
# MONITOR_INTERVAL seconds until q/Q is pressed (p/P pauses). Does NOT
# enter monitor mode and does NOT touch hostapd — it can run while the
# AP is live.
monitor_run_live() {
    local iface="${DEFAULTS[INTERFACE]:-}"
    [[ -n "${iface}" ]] || { warn "No interface configured for live monitor."; return 1; }

    _monitor_install_traps
    tput civis >&2 2>/dev/null

    local key=""
    local paused=false
    while true; do
        monitor_tick
        if read -r -t "${MONITOR_INTERVAL}" -n 1 -s key; then
            case "${key}" in
                q|Q)
                    break
                    ;;
                p|P)
                    paused=true
                    echo $'\n*** paused — press any key to resume ***' >&2
                    while read -r -t 1 -n 1 -s key; do
                        if [[ -n "${key}" ]]; then
                            break
                        fi
                    done
                    [[ "${key}" == "q" || "${key}" == "Q" ]] && break
                    paused=false
                    ;;
            esac
        fi
    done
    _monitor_finish
    _monitor_clear_traps
    return 0
}