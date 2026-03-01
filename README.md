# GhostAP - Wireless Access Point Creator

A comprehensive Bash script for creating wireless access points with advanced features including internet sharing, packet capture, DNS spoofing, proxy routing, and monitor mode capabilities.

## Features

- **Wireless Access Point Creation**: Set up secure (WPA2/WPA3) or open WiFi networks
- **AP Cloning**: Quickly clone existing networks by SSID with automatic configuration
- **Internet Sharing**: Share internet connection from another interface via NAT
- **Real-time Client Monitoring**: Track connected devices with MAC, IP, and hostname
- **Packet Capture**: Real-time traffic monitoring and PCAP export with tshark
- **DNS Spoofing**: Redirect specific domains to custom IP addresses
- **DoH Blocking**: Block DNS-over-HTTPS to enforce DNS spoofing
- **Proxy Integration**: Tool-agnostic support for local transparent proxies, redsocks (upstream), and remote DNAT
- **Intercept Traffic**: Easily bridge traffic to tools like `mitmproxy`, `Burp Suite`, or `Wireshark`
- **Interactive & CLI Modes**: Flexible configuration options
- **Configuration Management**: Save and load configurations with CLI argument overrides
- **Comprehensive Logging**: Detailed operation logs for all services

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

# For proxy routing
sudo apt install redsocks

# For advanced interception (optional)
# You can use tools like mitmproxy or Burp Suite
sudo apt install mitmproxy
```

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

## Usage

### Interactive Mode (Recommended for beginners)

```bash
sudo ./GhostAP.sh --interactive
```

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
sudo ./GhostAP.sh -i wlan0 --clone "Target_SSID"
```

#### Local Transparent Interception

```bash
sudo ./GhostAP.sh --local-proxy -s "InterceptAP"
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

| Option                          | Description                           |
| ------------------------------- | ------------------------------------- |
| `-i, --interface IFACE`         | Wireless interface to use             |
| `-si, --source-interface IFACE` | Source interface for internet sharing |
| `--clone SSID`                  | Clone an existing AP by SSID          |

### Network Options

| Option                  | Description                    |
| ----------------------- | ------------------------------ |
| `-s, --ssid SSID`       | Network name (SSID)            |
| `-c, --channel CHANNEL` | WiFi channel (1-14)            |
| `--security TYPE`       | Security type (open/wpa2/wpa3) |
| `--password PASSWORD`   | WiFi password (for WPA2/WPA3)  |
| `--subnet OCTET`        | Subnet third octet (0-255)     |
| `--dns IP`              | DNS server IP address          |
| `-m, --mac MAC`         | MAC address to use             |

### Feature Options

| Option              | Description                                                         |
| ------------------- | ------------------------------------------------------------------- |
| `--internet`        | Enable internet sharing                                             |
| `--capture [FILE]`  | Enable packet capture                                               |
| `--spoof "DOMAINS"` | Enable DNS spoofing (Format: `dom.com=1.2.3.4\|dom2.com\|...`)      |
| `--spoof-target IP` | Default target IP for DNS spoofing (when domain has no explicit IP) |
| `--block-doh`       | Block DNS-over-HTTPS to enforce DNS spoofing                        |

### Proxy Options

| Option              | Description                                                     |
| ------------------- | --------------------------------------------------------------- |
| `--local-proxy`     | Shortcut for `--proxy-mode TRANSPARENT_LOCAL`                   |
| `--remote-proxy`    | Shortcut for `--proxy-mode REMOTE_DNAT`                         |
| `--proxy`           | Shortcut for `--proxy-mode TRANSPARENT_UPSTREAM`                |
| `--proxy-mode MODE` | Proxy mode (TRANSPARENT_LOCAL/TRANSPARENT_UPSTREAM/REMOTE_DNAT) |
| `--proxy-host HOST` | Proxy server host/IP                                            |
| `--proxy-port PORT` | Proxy server port                                               |
| `--proxy-type TYPE` | Proxy type (http/socks4/socks5)                                 |
| `--proxy-user USER` | Proxy username                                                  |
| `--proxy-pass PASS` | Proxy password                                                  |

## Configuration Management

### Saving Configurations

```bash
sudo ./GhostAP.sh --save myconfig -i wlan0 -s "MyAP" --security wpa2 --password "password"
```

### Loading Configurations

```bash
sudo ./GhostAP.sh --config /path/to/myconfig.conf
```

> [!NOTE]
> Command-line arguments always take precedence over configuration file settings.

### Configuration File Format

```ini
# Network Configuration
INTERFACE="wlan0"
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
PROXY_BACKEND=""
PROXY_LOCATION=""
PROXY_HOST=""
PROXY_PORT=""
PROXY_TYPE=""
PROXY_USER=""
PROXY_PASS=""

# DNS Spoofing Options
SPOOF_DOMAINS=""
```

## Advanced Features

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

## Architecture

GhostAP uses a modular architecture with separate modules for each feature:

```
GhostAP/
├── GhostAP.sh           # Main entry point
└── src/
    ├── globals.sh       # Global variables and constants
    ├── utils.sh         # Logging, validation, cleanup functions
    ├── config.sh        # Configuration management and argument parsing
    ├── ui.sh            # User interface and status display
    ├── interface.sh     # Wireless interface management
    ├── hostapd.sh       # Access point configuration
    ├── dnsmasq.sh       # DHCP/DNS server and spoofing
    ├── internet.sh      # NAT and internet sharing
    ├── proxy.sh         # Proxy routing (Interception/Redsocks)
    ├── capture.sh       # Packet capture with tshark
    └── services.sh      # Service lifecycle management
```

````

## Monitoring and Logs

### Real-time Log Monitoring

```bash
tail -f Logs/GhostAP.log
````

### Service-specific Logs

- `Logs/hostapd.log` - Access point service logs
- `Logs/dnsmasq.log` - DHCP/DNS service logs
- `Logs/tshark.log` - Packet capture logs
- `Logs/redsocks.log` - Proxy service logs (when applicable)

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

Licensed under the Apache License, Version 2.0

## Support

For issues and questions:

1. Check the troubleshooting section
2. Review log files for error details
3. Ensure all dependencies are installed
4. Verify interface compatibility with AP mode

---

**Disclaimer**: This tool is intended for authorized network testing and educational purposes only. Unauthorized access to networks is illegal and unethical. Always obtain proper permission before testing network security.
