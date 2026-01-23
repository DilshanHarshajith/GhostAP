#!/bin/bash

get_wireless_interfaces() {
    local interfaces=()
    
    if command -v iw >/dev/null; then
        mapfile -t interfaces < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | sort -u)
    fi
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        mapfile -t interfaces < <(awk 'NR>2 {gsub(/:/, "", $1); print $1}' /proc/net/wireless 2>/dev/null | sort -u)
    fi
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        mapfile -t interfaces < <(find /sys/class/net -maxdepth 1 \( -name 'wl*' -o -name 'wlan*' \) -print0 2>/dev/null | xargs -0 -r basename -a | sort -u)
    fi
    
    [[ ${#interfaces[@]} -gt 0 ]] || error "No wireless interfaces found"
    printf '%s\n' "${interfaces[@]}"
}

get_internet_interfaces() {
    local interfaces=()
    local test_host="8.8.8.8"
    local retry=3

    mapfile -t all_ifaces < <(ip -o link show up | awk -F': ' '!/lo/ {print $2}')

    for iface in "${all_ifaces[@]}"; do
        for i in $(seq 1 "${retry}"); do
            if ping -I "${iface}" -c 1 -W 1 "${test_host}" &>/dev/null; then
                interfaces+=("${iface}")
                break
            fi
            sleep 1
        done
    done

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${interfaces[@]}"
}

get_network_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '/^[0-9]+:/ && !/lo:/ {gsub(/@.*/, "", $2); print $2}' | grep -v "^$" | sort -u || true
}

get_wifi_ssids() {
  local interface=${1:-"${DEFAULTS[INTERFACE]}"}  # Default interface wlan0, can be overridden by argument
  local ssids=()
  
  while IFS= read -r ssid_line; do
    [[ -n "$ssid_line" ]] && ssids+=("$ssid_line")
  done < <(sudo iwlist "$interface" scan | grep 'ESSID:' | sed -e 's/.*ESSID:"\(.*\)"/\1/')

  printf '%s\n' "${ssids[@]}"
}

get_ap_info() {
  local target_ssid="$1"
  local interface="${2:-wlan0}"

  sudo iwlist "$interface" scan | awk -v ssid="$target_ssid" '
    BEGIN {
      mac = ""; channel = ""; essid = "";
    }

    /Cell [0-9]+ - Address:/ {
      mac = $NF;
      channel = ""; essid = "";
    }

    /Channel:/ {
      channel = $2;
    }

    /Frequency:/ {
      match($0, /\(Channel ([0-9]+)\)/, arr);
      if (arr[1] != "") channel = arr[1];
    }

    /ESSID:/ {
      match($0, /ESSID:"(.*)"/, arr);
      essid = arr[1];
      if (essid == ssid && mac && channel) {
        print essid "|" channel "|" mac;
      }
    }
  '
}
