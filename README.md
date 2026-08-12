# GhostAP - Wireless Access Point Creator

A comprehensive Bash script for creating wireless access points with advanced features including internet sharing, packet capture, DNS spoofing, proxy routing, captive portal, and monitor mode capabilities.

## Features

- **Wireless Access Point Creation**: Set up secure (WPA2/WPA3) or open WiFi networks
- **Ethernet AP Mode**: Route traffic through downstream hardware without hostapd — works with a downstream router/AP, or a single PC plugged in directly via a straight ethernet cable
- **AP Cloning**: Quickly clone existing networks by SSID, or discover targets with a live/quick monitor-mode scan, with automatic configuration
- **AP Scanning**: Monitor-mode beacon scanning (BSSID, SSID, channel, security, signal) — live continuously-updating view or a standalone survey with `--scan-aps`
- **Internet Sharing**: Share internet connection from another interface via NAT
- **Real-time Client Monitoring**: Track connected devices with MAC, IP, and hostname
- **Packet Capture**: Real-time traffic monitoring and PCAP export with tshark
- **DNS Spoofing**: Redirect specific domains to custom IP addresses
- **Captive Portal**: Intercept clients with a customizable portal page; credentials are captured and clients are whitelisted on acceptance
- **Proxy Integration**: Tool-agnostic support for local transparent proxies, redsocks (upstream), and remote DNAT
- **VPN Routing**: Securely route all AP traffic through OpenVPN, WireGuard, or a pre-configured VPN interface
- **Configuration Management**: Save and load configurations with CLI argument overrides

## Requirements

### System Requirements

- Linux system with root access
- Bash version 4.0 or newer
- Wireless network interface capable of AP mode

### Required Dependencies

```bash
sudo apt update
sudo apt install hostapd dnsmasq wireless-tools net-tools iptables iproute2
```

### Optional Dependencies

```bash
# For packet capture
sudo apt install wireshark-common

# For AP cloning discovery and AP scanning (--scan-aps)
sudo apt install aircrack-ng

# For proxy routing
sudo apt install redsocks

# For VPN routing (optional)
sudo apt install openvpn wireguard-tools

# For advanced interception (optional)
sudo apt install mitmproxy
```

> [!NOTE]
> AP cloning discovery and `--scan-aps` briefly switch the wireless interface into monitor mode to capture beacon frames, which requires both `airodump-ng` (from `aircrack-ng`) and a driver/adapter that supports monitor mode (`iw list` → check for `monitor` under "Supported interface modes").

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/DilshanHarshajith/GhostAP.git
   cd GhostAP
   chmod +x GhostAP.sh
   ```

2. Run with root privileges:

   ```bash
   sudo ./GhostAP.sh
   ```

### Installation as Debian Package (Recommended)

1. Download the latest `.deb` package from the [Releases](https://github.com/DilshanHarshajith/GhostAP/releases) page.
2. Install using `apt`:

   ```bash
   sudo apt install ./ghostap_*.deb
   ```

3. Run from anywhere:

   ```bash
   sudo ghostap
   ```

## Usage

### Interactive Mode (Recommended for beginners)

```bash
sudo ./GhostAP.sh --interactive
```

> [!NOTE]
> Interactive mode automatically selects the default option when only one choice is available (e.g., when you only have one wireless interface).

### Quick Start Examples

#### Basic Open Access Point

```bash
sudo ./GhostAP.sh -i wlan0 -s "MyOpenAP" -c 6 --security open
```

#### Secure WPA2 Access Point with Internet Sharing

```bash
sudo ./GhostAP.sh -i wlan0 -s "MySecureAP" -c 6 --security wpa2 --password "password123" --internet -si eth0
```

#### Access Point with Packet Capture

```bash
sudo ./GhostAP.sh -i wlan0 -s "MonitorAP" --capture
# or
sudo ./GhostAP.sh -i wlan0 -s "MonitorAP" --capture "capture.pcap"
```

#### Access Point with Proxy Routing

```bash
sudo ./GhostAP.sh -i wlan0 -s "ProxyAP" --proxy --proxy-host 127.0.0.1 --proxy-port 8080 --proxy-type http
```

#### Clone an Existing Access Point

```bash
# Clone by SSID directly — resolved via a short scan (BSSID/channel/security
# picked up automatically; if multiple nearby APs share the SSID, the
# strongest-signal match is used and the ambiguity is logged)
sudo ./GhostAP.sh -i wlan0 --clone "Target_SSID"

# Interactive: no SSID given — offers a live, continuously-updating scan table
# to pick from (press any key to stop), or falls back to a quick scan + list
sudo ./GhostAP.sh -i wlan0 --int --clone
```

#### Scan for Nearby Access Points

```bash
# Standalone survey — no cloning, no AP setup, just look at what's nearby
# Live table in interactive mode (press any key to stop)
sudo ./GhostAP.sh -i wlan0 --int --scan-aps

# Fixed-duration snapshot (non-interactive), default 15s
sudo ./GhostAP.sh -i wlan0 --scan-aps
sudo ./GhostAP.sh -i wlan0 --scan-aps 20
```

#### Ethernet AP Mode (Downstream Router as Radio, or a Directly Connected PC)

`--eth-ap` skips hostapd and manages DHCP/NAT/features directly on an ethernet
port instead of a WiFi radio. The interface can face either a downstream
router (its WiFi radio serves the clients) or a single PC/laptop plugged in
directly with a straight ethernet cable — no switch or router needed in
between. In both cases GhostAP is the DHCP server and gateway for whatever is
on the other end of that cable, so the same DNS spoofing, proxy, capture, and
VPN-routing features apply.

```bash
# Downstream router in bridge/AP mode (disable its DHCP+NAT)
# Basic ethernet AP — internet shared from eth0, GhostAP manages DHCP on eth1
sudo ./GhostAP.sh --eth-ap -i eth1 --internet -si eth0

# Same command also works to hand internet + interface access straight to a
# second PC connected via an ethernet cable to eth1 — just set that PC's NIC
# to DHCP and it will pick up an address/gateway from GhostAP automatically.
```

#### Local Transparent Interception

```bash
sudo ./GhostAP.sh --local-proxy -s "InterceptAP"
```

#### Captive Portal (intercept clients before granting internet access)

```bash
# Built-in portal page with internet sharing
sudo ./GhostAP.sh -i wlan0 -s "FreeWifi" --security open --captive --internet -si eth0

# With a custom HTML template
sudo ./GhostAP.sh -i wlan0 -s "FreeWifi" --captive --internet -si eth0 \
    --captive-template /path/to/portal/index.html
```

#### Secure Access Point with VPN Routing

```bash
# Using an OpenVPN config
sudo ./GhostAP.sh -i wlan0 -s "VPNAccess" --vpn "/path/to/vpn.ovpn"

# Using a WireGuard config
sudo ./GhostAP.sh -i wlan0 -s "VPNAccess" --vpn "/path/to/wg0.conf"

# Routing through an existing VPN interface
sudo ./GhostAP.sh -i wlan0 -s "VPNAccess" --vpn-interface tun0
```

## Command Line Options

### Basic Options

| Option                 | Description                          |
| ---------------------- | ------------------------------------ |
| `--int, --interactive` | Start in interactive mode            |
| `--config FILE`        | Load configuration from file         |
| `--save NAME`          | Save current configuration with name |
| `--help`               | Show help message                    |

### Interface Options

| Option                          | Description                               |
| ------------------------------- | ----------------------------------------- |
| `-i, --interface IFACE`         | Interface to use (wireless, or ethernet with `--eth-ap`) |
| `-si, --source-interface IFACE` | Source interface for internet sharing     |
| `--eth-ap, --ethernet-ap`       | Enable Ethernet AP mode (skip hostapd)    |
| `--vpn [CONFIG]`                | Enable VPN routing (optional .ovpn/.conf) |
| `--vpn-interface IFACE`         | Use an existing VPN interface             |
| `--vpn-creds USER:PASS`         | OpenVPN credentials (non-interactive)     |
| `--clone SSID`                  | Clone an existing AP by SSID              |

> [!NOTE]
> `--clone SSID` resolves the target via a short monitor-mode scan (not a saved network list) — the AP must be in range and broadcasting at the time GhostAP runs.

### Scan Options

| Option                | Description                                                              |
| ---------------------- | ------------------------------------------------------------------------- |
| `--scan-aps [SECONDS]` | Standalone AP survey: prints nearby APs (BSSID, SSID, channel, security, signal) and exits — no cloning, no AP setup. Live table in interactive mode; fixed duration otherwise (default: 15s). |

### Network Options

| Option                  | Description                    |
| ----------------------- | ------------------------------ |
| `-s, --ssid SSID`       | Network name (SSID)            |
| `-c, --channel CHANNEL` | WiFi channel (1-14)            |
| `--security TYPE`       | Security type (open/wpa2/wpa3) |
| `--password PASSWORD`   | WiFi password (for WPA2/WPA3)  |
| `--subnet OCTET`        | Subnet third octet (0-255)     |
| `--dns IP`              | DNS server IP address          |
| `-m, --mac MAC`         | MAC address to use (wireless mode only) |

### Feature Options

| Option              | Description                                                         |
| ------------------- | ------------------------------------------------------------------- |
| `--internet`        | Enable internet sharing                                             |
| `--capture [FILE]`  | Enable packet capture                                               |
| `--spoof "DOMAINS"` | Enable DNS spoofing (Format: `dom.com=1.2.3.4\|dom2.com\|...`)      |
| `--spoof-target IP` | Default target IP for DNS spoofing (when domain has no explicit IP) |
| `--block-doh`       | Block DNS-over-HTTPS to enforce DNS spoofing                        |

### Proxy Options

| Option              | Description                                      |
| ------------------- | ------------------------------------------------ |
| `--local-proxy`     | Redirect traffic to local port (default 8080)    |
| `--remote-proxy`    | Redirect traffic to a remote host/port (DNAT)    |
| `--proxy`           | Redirect traffic to an upstream proxy (redsocks) |
| `--proxy-host HOST` | Proxy server host/IP                             |
| `--proxy-port PORT` | Proxy server port                                |
| `--proxy-type TYPE` | Proxy type (http/socks4/socks5)                  |
| `--proxy-user USER` | Proxy username                                   |
| `--proxy-pass PASS` | Proxy password                                   |

### Captive Portal Options

| Option                    | Description                                                  |
| ------------------------- | ------------------------------------------------------------ |
| `--captive`               | Enable captive portal (intercepts clients until they submit) |
| `--captive-port PORT`     | Port for the captive portal server (default: `8880`)         |
| `--captive-template FILE` | Path to a custom HTML file to use as the portal page         |

## Configuration Management

### Saving Configurations

```bash
sudo ./GhostAP.sh --save myconfig -i wlan0 -s "MyAP" --security wpa2 --password "password"
```

### Loading Configurations

```bash
sudo ./GhostAP.sh --config /path/to/myconfig.conf
# Relative paths are also supported:
sudo ./GhostAP.sh --config myconfig.conf
```

> [!NOTE]
> Command-line arguments always take precedence over configuration file settings.

### Configuration File Format

```ini
# Network Configuration
INTERFACE="wlan0"
ETHERNET_MODE="false"
SSID="MyAccessPoint"
CHANNEL="6"
SUBNET="10"
DNS="8.8.8.8"
SECURITY="wpa2"
PASSWORD="mypassword"

# Features
INTERNET_SHARING="true"
SOURCE_INTERFACE="eth0"
DNS_SPOOFING="false"
PACKET_CAPTURE="true"

# Cloning Options
CLONE="false"
CLONE_SSID=""

# Proxy Options
PROXY_ENABLED="false"
PROXY_MODE="TRANSPARENT_LOCAL"
PROXY_HOST=""
PROXY_PORT=""
PROXY_TYPE=""
PROXY_USER=""
PROXY_PASS=""

# VPN Options
VPN_ROUTING="false"
VPN_INTERFACE=""
VPN_CONFIG=""
VPN_CREDS=""

# DNS Spoofing Options
SPOOF_DOMAINS=""
SPOOF_TARGET_IP=""
BLOCK_DOH="false"

# Captive Portal Options
CAPTIVE_PORTAL="false"
CAPTIVE_PORT="8880"
CAPTIVE_TEMPLATE=""
```

## Advanced Features

### AP Scanning & Clone Discovery

GhostAP discovers nearby access points by briefly switching the wireless interface into monitor mode and capturing beacon frames with `airodump-ng` (channel hopping is handled by airodump-ng itself, restricted to the same channel set GhostAP scans) — rather than relying on a cached network list. This is used both for AP cloning and for the standalone `--scan-aps` survey.

**What's captured per AP:**

- **BSSID** — exact MAC address, so networks sharing an SSID can be told apart
- **SSID** — read directly from airodump-ng's CSV output (blank for hidden networks)
- **Channel** and **signal strength** (dBm)
- **Security** — classified as open/WPA2/WPA3 from airodump-ng's Privacy/Authentication columns (e.g. `SAE` → WPA3), not guessed from the privacy bit alone

**Two scan modes:**

- **Live** (interactive only): a continuously-updating table, refreshed roughly once per second. Stop it by pressing any key, then pick an AP from the list.
- **Quick / fixed-duration**: a short scan window (default 10s for clone discovery, 15s for `--scan-aps`) with no live rendering — used automatically in non-interactive contexts, or as the default interactive picker if you skip the live scan.

**Resolving `--clone "SSID"` directly:** a short scan runs to find that SSID, and if multiple nearby APs are broadcasting the same name, the strongest-signal match is used and the ambiguity is logged rather than silently picking one.

**Explicit overrides always win:** if you pass `--ssid`, `--channel`, `--mac`, or `--security` alongside `--clone`, those values are kept as-is and the corresponding scanned value is discarded (and logged).

> [!NOTE]
> Scanning only observes what access points broadcast (beacons) — it does not track or fingerprint client devices. Only clone or scan networks you own or have explicit permission to test.

### DNS Spoofing

Redirect specific domains to custom IP addresses:

```bash
# Spoof specific domains with explicit IPs
sudo ./GhostAP.sh --spoof "example.com=192.168.1.100|test.com=10.0.0.1"

# Spoof domains to default target (AP IP or custom target)
sudo ./GhostAP.sh --spoof "example.com|test.com" --spoof-target 192.168.1.50

# Mix explicit and default targets
sudo ./GhostAP.sh --spoof "example.com=192.168.1.100|test.com" --spoof-target 10.0.0.1

# Spoof with DoH blocking to prevent DNS bypass
sudo ./GhostAP.sh --spoof "example.com" --block-doh
```

> [!NOTE]
> When DNS spoofing is enabled without `--spoof-target`, domains without explicit IPs default to the AP's IP address (192.168.X.1).

<!-- -->

> [!IMPORTANT]
> Use `--block-doh` to block DNS-over-HTTPS traffic and force clients to use your DNS server. This prevents clients from bypassing DNS spoofing by using encrypted DNS services like Google DoH or Cloudflare DoH.

Captured packets are saved to the current directory (or specified path) with timestamps:

```bash
ls -la *.pcap
```

### Proxy Routing

GhostAP supports three advanced proxying modes in a tool-agnostic manner:

#### 1. Local Transparent Proxy (`--local-proxy` or `--proxy-mode TRANSPARENT_LOCAL`)

Redirects client traffic to a local port (default 8080) for interception:

- Transparently redirects HTTP (80) and HTTPS (443) traffic.
- Allows you to manually run your favorite tool (e.g., `mitmproxy`, `Burp Suite`) on the specified port.
- Traffic flow: `Client → AP → Local Interceptor (8080) → Internet`

```bash
sudo ./GhostAP.sh --local-proxy -s "InterceptAP"
# Now start your interceptor tool on port 8080
```

#### 2. Upstream Proxy (`--proxy` or `--proxy-mode TRANSPARENT_UPSTREAM`)

Forwards intercepted traffic to an external HTTP or SOCKS proxy using `redsocks`:

- Transparently redirects traffic to an upstream proxy server.
- Supports HTTP, SOCKS4, and SOCKS5 proxies.
- Supports authenticated proxies (username/password).
- Traffic flow: `Client → AP → Redsocks → External Proxy → Internet`

```bash
sudo ./GhostAP.sh --proxy --proxy-host 10.0.0.5 --proxy-port 3128 --proxy-type http
```

#### 3. Remote Forwarding (`--remote-proxy` or `--proxy-mode REMOTE_DNAT`)

Simple DNAT forwarding to a remote IP/Port:

- Useful if your interception tool is running on a different machine.
- No local proxy process is started.
- Traffic flow: `Client → AP → Remote Host (DNAT)`

```bash
sudo ./GhostAP.sh --remote-proxy --proxy-host 10.0.0.10 --proxy-port 8080
```

### Connected Devices Monitoring

The script monitors connected clients in real-time by watching DHCP leases. It displays:

- MAC Address
- Assigned IP Address
- Device Hostname (if available)

### VPN Routing

GhostAP provides robust VPN routing using Policy-Based Routing (PBR):

- **Traffic Isolation**: All traffic from the AP is routed through the VPN tunnel.
- **Kill Switch**: Built-in firewall rules prevent traffic leaks if the VPN connection drops.
- **Multiple Backends**:
  - **OpenVPN**: Full support for `.ovpn` configurations with credential management.
  - **WireGuard**: Native support for `.conf` profiles.
  - **Existing Interface**: Use already running VPN tunnels (tun, wg, proton, etc.).
- **Automatic Configuration**: Detects and configures routing tables and NAT rules automatically.

```bash
# Enable VPN with an OpenVPN profile
sudo ./GhostAP.sh --vpn client.ovpn --vpn-creds "user:pass"
```

> [!CAUTION]
> When VPN routing is enabled, a kill switch is active. This will block all internet traffic from clients if the VPN interface is not up.

### Captive Portal

GhostAP can intercept connecting clients with a captive portal — the same mechanism used by hotel and airport Wi-Fi networks. Clients are blocked from internet access until they submit the portal form (e.g. accept terms, enter credentials).

**How it works:**

1. DNS wildcard (`address=/#/...`) in dnsmasq redirects all lookups to the AP.
2. An `iptables` rule redirects all client HTTP traffic to the built-in Python portal server.
3. HTTPS is blocked with a TCP-reset until the client is whitelisted.
4. When a client submits the form (`POST /accept`), the server:
   - Logs any submitted fields (credentials, etc.) to a timestamped file in `Output/`.
   - Inserts per-client `iptables` rules to allow full internet access.
   - Restores the client's DNS to the real upstream server.
5. OS captive-portal detection probes (iOS, Android, Windows, Firefox) are handled so the "Sign in to network" dialog appears automatically.

**Custom templates:**

You can supply your own HTML portal page. The entire directory containing the specified file is served, preserving any folder structure (CSS, JS, images, sub-directories). The supplied file becomes the entry point (`index.html`). The form **must** POST to `/accept` to trigger client whitelisting.

```bash
# Built-in portal
sudo ./GhostAP.sh -i wlan0 -s "FreeWifi" --security open --captive --internet -si eth0

# Custom template
sudo ./GhostAP.sh --captive --captive-template /path/to/portal/login.html --internet -si eth0

# Custom port
sudo ./GhostAP.sh --captive --captive-port 9090 --internet -si eth0
```

> [!NOTE]
> Captive portal requires `python3`. Captured credentials are saved to `Output/captive_credentials-<timestamp>.txt`.

<!-- -->

> [!WARNING]
> Using captive portal together with `--proxy` or `--spoof` may cause conflicts, as all three features manipulate HTTP traffic and/or DNS. Use only one at a time.

## Architecture

GhostAP uses a modular architecture with separate modules for each feature:

```text
GhostAP/
├── GhostAP.sh           # Main entry point
└── src/
    ├── globals.sh       # Global variables and constants
    ├── utils.sh         # Logging, validation, cleanup functions
    ├── network.sh       # Interface discovery (wireless/ethernet/internet-connected)
    ├── config.sh        # Configuration management and argument parsing
    ├── ui.sh            # User interface and status display
    ├── interface.sh     # Wireless interface management, AP cloning flow
    ├── scan.sh          # Monitor-mode AP scanning via airodump-ng (clone discovery, --scan-aps)
    ├── vpn.sh           # VPN routing (OpenVPN/WireGuard/existing interface)
    ├── hostapd.sh       # Access point configuration
    ├── dnsmasq.sh       # DHCP/DNS server and spoofing
    ├── internet.sh      # NAT and internet sharing
    ├── proxy.sh         # Proxy routing (Interception/Redsocks)
    ├── capture.sh       # Packet capture with tshark
    ├── captive.sh       # Captive portal server and iptables whitelisting
    └── services.sh      # Service lifecycle management
```

## Monitoring and Logs

### Real-time Log Monitoring

```bash
tail -f Logs/GhostAP.log
```

### Service-specific Logs

- `Logs/hostapd.log` - Access point service logs
- `Logs/dnsmasq.log` - DHCP/DNS service logs
- `Logs/tshark.log` - Packet capture logs
- `Logs/airodump.log` - AP scanning (cloning/`--scan-aps`) logs
- `Logs/redsocks.log` - Proxy service logs (when applicable)
- `Logs/captive.log` - Captive portal server logs (when applicable)

## Security Considerations

⚠️ **Important Security Notes:**

1. **Legal Usage**: Only use this tool on networks you own or have explicit permission to test
2. **Packet Capture**: May capture sensitive information - handle responsibly
3. **DNS Spoofing**: Can redirect legitimate traffic - use carefully
4. **Proxy Routing**: All traffic may be intercepted - ensure proper authorization

## Troubleshooting

### Common Issues

#### Interface Not Found

```bash
# List available wireless interfaces
iw dev
```

#### Permission Denied

```bash
# Ensure running as root
sudo ./GhostAP.sh
```

#### Service Start Failures

```bash
# Check system logs
journalctl -u hostapd
journalctl -u dnsmasq
```

#### No Internet Access

- Verify source interface has internet connectivity
- Check iptables rules: `iptables -L -n -t nat`
- Ensure IP forwarding is enabled: `cat /proc/sys/net/ipv4/ip_forward`

#### Scan / Clone Discovery Shows No APs

- Verify `airodump-ng` (part of `aircrack-ng`) is installed and either running as root or the adapter/driver otherwise permits monitor-mode capture.
- Confirm the wireless adapter/driver supports monitor mode: `iw list` and check for `monitor` under "Supported interface modes".
- Some drivers need a brief settle time after switching to monitor mode. The quick picker and `--clone "SSID"` use a fixed ~10s window; if that's not enough, try the live scan instead (`--int --clone`, or `--int --scan-aps`) and let it run longer before pressing a key.
- Check `Logs/airodump.log` for capture errors.

### Debug Mode

Enable debug logging:

```bash
DEBUG=1 sudo ./GhostAP.sh
```

## Stopping the Access Point

Press `Ctrl+C` to gracefully stop the access point. The script will:

- Terminate all started services
- Remove iptables rules
- Restore interface to managed mode
- Clean up temporary files
- Save packet captures (if enabled)

## Contributing

Contributions are welcome! Please ensure:

- Code follows existing style conventions
- New features include appropriate error handling
- Documentation is updated for new options
- Security implications are considered

## License

Licensed under the GNU General Public License v3

## Support

For issues and questions:

1. Check the troubleshooting section
2. Review log files for error details
3. Ensure all dependencies are installed
4. Verify interface compatibility with AP mode

---

**Disclaimer**: This tool is intended for authorized network testing and educational purposes only. Unauthorized access to networks is illegal and unethical. Always obtain proper permission before testing network security.