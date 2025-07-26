# GhostAP - Wireless Access Point Creator

A comprehensive Bash script for creating wireless access points with advanced features including internet sharing, packet capture, DNS spoofing, proxy routing, and monitor mode capabilities.

## Features

- **Wireless Access Point Creation**: Set up secure or open WiFi networks
- **Internet Sharing**: Share internet connection from another interface
- **Packet Capture**: Real-time traffic monitoring with tshark
- **DNS Spoofing**: Redirect domains to custom IP addresses
- **Proxy Integration**: Support for mitmproxy and redsocks
- **Monitor Mode**: Enable wireless monitoring capabilities
- **Interactive & CLI Modes**: Flexible configuration options
- **Configuration Management**: Save and load configurations
- **Comprehensive Logging**: Detailed operation logs

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

# For advanced proxy features
pip install mitmproxy
```

## Installation

1. Download the script:
```bash
wget https://github.com/DilshanHarshajith/GhostAP/blob/main/GhostAP.sh
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
sudo ./GhostAP.sh -i wlan0 -s "MySecureAP" -c 6 --security wpa2 -p "password123" --internet -si eth0
```

#### Access Point with Packet Capture
```bash
sudo ./GhostAP.sh -i wlan0 -s "MonitorAP" --capture --monitor
```

#### Access Point with Proxy Routing
```bash
sudo ./GhostAP.sh -i wlan0 -s "ProxyAP" --proxy --proxy-host 127.0.0.1 --proxy-port 8080 --proxy-type http
```

## Command Line Options

### Basic Options
| Option | Description |
|--------|-------------|
| `--int, --interactive` | Start in interactive mode |
| `--config FILE` | Load configuration from file |
| `--save NAME` | Save current configuration with name |
| `--help` | Show help message |

### Interface Options
| Option | Description |
|--------|-------------|
| `-i, --interface IFACE` | Wireless interface to use |
| `-si, --source-interface IFACE` | Source interface for internet sharing |

### Network Options
| Option | Description |
|--------|-------------|
| `-s, --ssid SSID` | Network name (SSID) |
| `-c, --channel CHANNEL` | WiFi channel (1-14) |
| `--security TYPE` | Security type (open/wpa2/wpa3) |
| `-p, --password PASSWORD` | WiFi password (for WPA2/WPA3) |
| `--subnet OCTET` | Subnet third octet (0-255) |
| `--dns IP` | DNS server IP address |

### Feature Options
| Option | Description |
|--------|-------------|
| `--monitor` | Enable monitor mode |
| `--internet` | Enable internet sharing |
| `--capture` | Enable packet capture |
| `--spoof [DOMAINS]` | Enable DNS spoofing |

### Proxy Options
| Option | Description |
|--------|-------------|
| `--mitmlocal` | Use mitmproxy locally |
| `--mitmremote` | Use mitmproxy remotely |
| `--proxy` | Use redsocks proxy |
| `--proxy-host HOST` | Proxy server host/IP |
| `--proxy-port PORT` | Proxy server port |
| `--proxy-type TYPE` | Proxy type (http/socks4/socks5) |
| `--proxy-user USER` | Proxy username |
| `--proxy-pass PASS` | Proxy password |

## Configuration Management

### Saving Configurations
```bash
sudo ./GhostAP.sh --save myconfig -i wlan0 -s "MyAP" --security wpa2 -p "password"
```

### Loading Configurations
```bash
sudo ./GhostAP.sh --config /path/to/myconfig.conf
```

### Configuration File Format
```ini
SSID="MyAccessPoint"
CHANNEL="6"
SUBNET="10"
DNS="8.8.8.8"
SECURITY="wpa2"
PASSWORD="mypassword"
INTERNET_SHARING="true"
DNS_SPOOFING="false"
PACKET_CAPTURE="true"
MONITOR_MODE="false"
PROXY_ENABLED="false"
```

## Advanced Features

### DNS Spoofing
Redirect specific domains to custom IP addresses:
```bash
sudo ./GhostAP.sh --spoof "example.com=192.168.1.100|test.com=10.0.0.1"
```

### Packet Capture
Captured packets are saved to the `Output` directory with timestamps:
```bash
ls -la Output/*.pcap
```

### Proxy Routing
Three proxy modes available:
1. **Local mitmproxy**: `--mitmlocal`
2. **Remote mitmproxy**: `--mitmremote`
3. **Redsocks**: `--proxy`

## Directory Structure

The script creates the following directory structure:
```
GhostAP/
├── Config/          # Configuration files
├── Logs/           # Log files
├── Output/         # Packet captures
└── Temp/           # Temporary files
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
- `Logs/redsocks.log` - Proxy service logs (when applicable)

## Security Considerations

⚠️ **Important Security Notes:**

1. **Legal Usage**: Only use this tool on networks you own or have explicit permission to test
2. **Monitor Mode**: Can interfere with normal wireless operations
3. **Packet Capture**: May capture sensitive information - handle responsibly
4. **DNS Spoofing**: Can redirect legitimate traffic - use carefully
5. **Proxy Routing**: All traffic may be intercepted - ensure proper authorization

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