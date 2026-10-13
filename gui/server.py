#!/usr/bin/env python3
"""GhostAP Web GUI backend.

A dependency-free (Python standard library only) local web server that drives
the existing ``GhostAP.sh`` Bash tool. It exposes a small JSON API for
inspecting interfaces, starting/stopping the access point, streaming logs,
listing connected clients, scanning for nearby APs, and saving/loading
setups. The front-end lives in ``gui/static``.

The GUI is a thin control surface: it never reimplements the AP itself, it
builds a command line for ``GhostAP.sh`` and supervises the child process.

Run it as root (the AP needs root):

    sudo ./gui/run.sh

or directly:

    sudo python3 gui/server.py --port 8787

The server binds to 127.0.0.1 by default so it is not reachable off-host.
"""

from __future__ import annotations

import argparse
import json
import os
import pwd
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

GUI_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(GUI_DIR)
STATIC_DIR = os.path.join(GUI_DIR, "static")
GHOSTAP_SH = os.path.join(REPO_DIR, "GhostAP.sh")


def _user_home() -> str:
    """Mirror src/globals.sh: use SUDO_USER's home when running under sudo."""
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        try:
            return pwd.getpwnam(sudo_user).pw_dir
        except KeyError:
            pass
    return os.path.expanduser("~")


APP_DIR = os.path.join(_user_home(), "GhostAP")
SETUP_DIR = os.path.join(APP_DIR, "Setups")
LOG_DIR = os.path.join(APP_DIR, "Logs")
TMP_DIR = os.path.join(APP_DIR, "Temp")
LOG_FILE = os.path.join(LOG_DIR, "GhostAP.log")
LEASE_FILE = os.path.join(TMP_DIR, "dhcp.leases")

# When the server is not root we fall back to non-interactive sudo (-n) so we
# never hang waiting for a password prompt. Run the server with sudo instead.
USE_SUDO = os.geteuid() != 0


def _run_prefix() -> list[str]:
    return ["sudo", "-n"] if USE_SUDO else []


# ---------------------------------------------------------------------------
# GUI configuration schema
# ---------------------------------------------------------------------------

# Every field the GUI collects. ``default`` is used when the front-end omits a
# key. Booleans are stored as real bools here and converted to "true"/"false"
# for the .conf format or flags on the command line.
FIELDS = {
    "ethernet_mode": False,
    "interface": "",
    "source_interface": "",
    "ssid": "WiFi_AP",
    "channel": "6",
    "security": "open",
    "password": "",
    "subnet": "10",
    "dns": "8.8.8.8",
    "mac": "",
    "internet": False,
    "capture": False,
    "capture_file": "",
    "clone": False,
    "clone_ssid": "",
    "spoof": False,
    "spoof_domains": "",
    "spoof_target": "",
    "block_doh": False,
    "proxy": False,
    "proxy_mode": "TRANSPARENT_LOCAL",
    "proxy_host": "",
    "proxy_port": "8080",
    "proxy_type": "http",
    "proxy_user": "",
    "proxy_pass": "",
    "vpn": False,
    "vpn_config": "",
    "vpn_interface": "",
    "vpn_creds": "",
    "captive": False,
    "captive_port": "8880",
    "captive_template": "",
}

# GUI key -> saved-config key (matches DEFAULTS keys in src/globals.sh).
CONF_KEYS = {
    "ethernet_mode": "ETHERNET_MODE",
    "interface": "INTERFACE",
    "source_interface": "SOURCE_INTERFACE",
    "ssid": "SSID",
    "channel": "CHANNEL",
    "security": "SECURITY",
    "password": "PASSWORD",
    "subnet": "SUBNET",
    "dns": "DNS",
    "mac": "MAC",
    "internet": "INTERNET_SHARING",
    "capture": "PACKET_CAPTURE",
    "capture_file": "CAPTURE_FILE",
    "clone": "CLONE",
    "clone_ssid": "CLONE_SSID",
    "spoof": "DNS_SPOOFING",
    "spoof_domains": "SPOOF_DOMAINS",
    "spoof_target": "SPOOF_TARGET_IP",
    "block_doh": "BLOCK_DOH",
    "proxy": "PROXY_ENABLED",
    "proxy_mode": "PROXY_MODE",
    "proxy_host": "PROXY_HOST",
    "proxy_port": "PROXY_PORT",
    "proxy_type": "PROXY_TYPE",
    "proxy_user": "PROXY_USER",
    "proxy_pass": "PROXY_PASS",
    "vpn": "VPN_ROUTING",
    "vpn_config": "VPN_CONFIG",
    "vpn_interface": "VPN_INTERFACE",
    "vpn_creds": "VPN_CREDS",
    "captive": "CAPTIVE_PORTAL",
    "captive_port": "CAPTIVE_PORT",
    "captive_template": "CAPTIVE_TEMPLATE",
}
CONF_TO_FIELD = {v: k for k, v in CONF_KEYS.items()}
BOOL_FIELDS = {k for k, v in FIELDS.items() if isinstance(v, bool)}

CHANNEL_RE = re.compile(r"^[0-9]+$")
MAC_RE = re.compile(r"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
IP_RE = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$")


# ---------------------------------------------------------------------------
# Log bus (ring buffer + SSE fan-out)
# ---------------------------------------------------------------------------


class LogBus:
    def __init__(self, maxlen: int = 2000) -> None:
        self._lock = threading.Lock()
        self._buffer: deque[str] = deque(maxlen=maxlen)
        self._subs: set[queue.Queue] = set()

    def publish(self, line: str) -> None:
        with self._lock:
            self._buffer.append(line)
            subs = list(self._subs)
        for q in subs:
            try:
                q.put_nowait(line)
            except queue.Full:
                pass

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=1000)
        with self._lock:
            self._subs.add(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            self._subs.discard(q)

    def recent(self, limit: int = 500) -> list[str]:
        with self._lock:
            lines = list(self._buffer)
        return lines[-limit:]

    def seed_from_file(self, path: str, limit: int = 200) -> None:
        try:
            with open(path, "r", errors="replace") as fh:
                tail = list(deque(fh, maxlen=limit))
        except OSError:
            return
        for line in tail:
            self.publish(line.rstrip("\n"))


# ---------------------------------------------------------------------------
# AP process manager
# ---------------------------------------------------------------------------


class APManager:
    def __init__(self, bus: LogBus) -> None:
        self._bus = bus
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._config: dict = {}
        self._started_at: float = 0.0
        self._stopping = False
        self._last_error = ""

    # -- helpers -----------------------------------------------------------
    def _set_proc(self, proc: subprocess.Popen | None) -> None:
        with self._lock:
            self._proc = proc
            if proc is None:
                self._stopping = False

    def status(self) -> dict:
        with self._lock:
            proc = self._proc
            cfg = dict(self._config)
            started = self._started_at
            stopping = self._stopping
            err = self._last_error
        running = proc is not None and proc.poll() is None
        return {
            "running": running,
            "stopping": stopping,
            "pid": proc.pid if (proc is not None and running) else None,
            "uptime": int(time.time() - started) if (running and started) else 0,
            "config": cfg,
            "error": err,
            "use_sudo": USE_SUDO,
            "ghostap": GHOSTAP_SH,
        }

    # -- lifecycle ---------------------------------------------------------
    def start(self, cfg: dict) -> tuple[bool, str]:
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return False, "Access point is already running."

        args = build_args(cfg)
        cmd = _run_prefix() + ["bash", GHOSTAP_SH] + args

        env = os.environ.copy()
        env.setdefault("TERM", "dumb")

        try:
            proc = subprocess.Popen(
                cmd,
                cwd=REPO_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                text=True,
                bufsize=1,
                start_new_session=True,
                env=env,
            )
        except OSError as exc:
            self._last_error = f"Failed to launch GhostAP: {exc}"
            return False, self._last_error

        with self._lock:
            self._proc = proc
            self._config = cfg
            self._started_at = time.time()
            self._stopping = False
            self._last_error = ""

        self._bus.publish(f"[gui] $ {' '.join(cmd)}")
        threading.Thread(target=self._reader, args=(proc,), daemon=True).start()
        return True, "Access point starting."

    def _reader(self, proc: subprocess.Popen) -> None:
        assert proc.stdout is not None
        try:
            for raw in iter(proc.stdout.readline, ""):
                self._bus.publish(raw.rstrip("\n"))
        except (ValueError, OSError):
            pass
        finally:
            try:
                proc.stdout.close()
            except OSError:
                pass
            code = proc.wait()
            with self._lock:
                if self._proc is proc:
                    self._proc = None
                    self._stopping = False
            self._bus.publish(f"[gui] GhostAP exited (code {code}).")

    def stop(self) -> tuple[bool, str]:
        with self._lock:
            proc = self._proc
            already = self._stopping
        if proc is None or proc.poll() is not None:
            return False, "Access point is not running."
        if already:
            return True, "Already stopping."

        with self._lock:
            self._stopping = True
        self._bus.publish("[gui] Stopping access point (SIGINT)...")
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGINT)
        except (ProcessLookupError, PermissionError):
            try:
                proc.send_signal(signal.SIGINT)
            except OSError:
                pass

        threading.Thread(target=self._reap, args=(proc,), daemon=True).start()
        return True, "Stopping."

    def _reap(self, proc: subprocess.Popen) -> None:
        # Cleanup can restart NetworkManager and can take a while; give it
        # plenty of room before resorting to SIGKILL.
        try:
            proc.wait(timeout=45)
            return
        except subprocess.TimeoutExpired:
            pass
        self._bus.publish("[gui] Graceful stop timed out; forcing kill.")
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                proc.kill()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Command-line builder + validation
# ---------------------------------------------------------------------------


def _norm_config(data: dict) -> dict:
    cfg = dict(FIELDS)
    for key in FIELDS:
        if key in data:
            value = data[key]
            if key in BOOL_FIELDS:
                cfg[key] = bool(value)
            else:
                cfg[key] = "" if value is None else str(value)
    return cfg


def validate_config(cfg: dict) -> list[str]:
    errors: list[str] = []

    if not cfg["interface"]:
        errors.append("An interface must be selected.")
    if not cfg["ethernet_mode"] and not cfg["clone"]:
        if not cfg["ssid"]:
            errors.append("SSID is required.")
        if not CHANNEL_RE.match(str(cfg["channel"])):
            errors.append("Channel must be a number.")
        elif not _valid_channel(int(cfg["channel"])):
            errors.append("Invalid channel (2.4GHz: 1-14, 5GHz: supported 20MHz channels).")
    if cfg["security"] not in ("open", "wpa2", "wpa3"):
        errors.append("Security must be open, wpa2, or wpa3.")
    if cfg["security"] != "open" and not cfg["clone"]:
        if not (8 <= len(cfg["password"]) <= 63):
            errors.append("Password must be 8-63 characters for WPA2/WPA3.")
    if cfg["subnet"] and not (str(cfg["subnet"]).isdigit() and 0 <= int(cfg["subnet"]) <= 255):
        errors.append("Subnet must be an octet (0-255).")
    if cfg["dns"] and not _valid_ip(cfg["dns"]):
        errors.append("DNS must be a valid IPv4 address.")
    if cfg["mac"] and not MAC_RE.match(cfg["mac"]):
        errors.append("MAC address must look like aa:bb:cc:dd:ee:ff.")
    if cfg["spoof"] and cfg["spoof_target"] and not _valid_ip(cfg["spoof_target"]):
        errors.append("Spoof target must be a valid IPv4 address.")
    if cfg["proxy"]:
        if cfg["proxy_mode"] in ("TRANSPARENT_UPSTREAM", "REMOTE_DNAT") and not cfg["proxy_host"]:
            errors.append("Proxy host is required for this proxy mode.")
        if cfg["proxy_port"] and not _valid_port(cfg["proxy_port"]):
            errors.append("Proxy port must be 1-65535.")
    if cfg["captive"] and cfg["captive_port"] and not _valid_port(cfg["captive_port"]):
        errors.append("Captive portal port must be 1-65535.")
    if cfg["captive"] and (cfg["proxy"] or cfg["spoof"]):
        errors.append("Captive portal cannot be combined with proxy or DNS spoofing.")
    if cfg["clone"] and cfg["ethernet_mode"]:
        errors.append("Cloning is only available in WiFi mode.")
    if cfg["clone"] and not cfg["clone_ssid"]:
        errors.append("Set a clone target SSID (use the Scan tab) or disable cloning.")
    return errors


def _valid_ip(value: str) -> bool:
    if not IP_RE.match(value):
        return False
    return all(0 <= int(p) <= 255 for p in value.split("."))


def _valid_port(value: str) -> bool:
    return str(value).isdigit() and 1 <= int(value) <= 65535


def _valid_channel(channel: int) -> bool:
    if 1 <= channel <= 14:
        return True
    if 36 <= channel <= 64 and channel % 4 == 0:
        return True
    if 100 <= channel <= 144 and channel % 4 == 0:
        return True
    if 149 <= channel <= 165 and (channel % 4 == 1 or channel == 165):
        return True
    return False


def build_args(cfg: dict) -> list[str]:
    args: list[str] = []

    if cfg["ethernet_mode"]:
        args.append("--eth-ap")
    if cfg["interface"]:
        args += ["-i", cfg["interface"]]

    if cfg["clone"]:
        # The scan decides SSID/channel/security; only the password can't be
        # sniffed, so pass it through for a WPA/WPA2/WPA3 clone.
        args.append("--clone")
        if cfg["clone_ssid"]:
            args += [cfg["clone_ssid"]]
        if cfg["password"]:
            args += ["--password", cfg["password"]]
    else:
        if cfg["ssid"]:
            args += ["-s", cfg["ssid"]]
        if cfg["channel"]:
            args += ["-c", str(cfg["channel"])]
        if cfg["security"]:
            args += ["--security", cfg["security"]]
        if cfg["security"] != "open" and cfg["password"]:
            args += ["--password", cfg["password"]]

    if cfg["subnet"]:
        args += ["--subnet", str(cfg["subnet"])]
    if cfg["dns"]:
        args += ["--dns", cfg["dns"]]
    if cfg["mac"] and not cfg["ethernet_mode"] and not cfg["clone"]:
        args += ["-m", cfg["mac"]]

    if cfg["internet"] or cfg["source_interface"]:
        if cfg["source_interface"]:
            args += ["-si", cfg["source_interface"]]
        else:
            args.append("--internet")

    if cfg["capture"]:
        args.append("--capture")
        if cfg["capture_file"]:
            args += [cfg["capture_file"]]

    if cfg["spoof"]:
        args.append("--spoof")
        if cfg["spoof_domains"]:
            args += [cfg["spoof_domains"]]
        if cfg["spoof_target"]:
            args += ["--spoof-target", cfg["spoof_target"]]
        if cfg["block_doh"]:
            args.append("--block-doh")

    if cfg["proxy"]:
        mode = cfg["proxy_mode"]
        if mode == "TRANSPARENT_LOCAL":
            args.append("--local-proxy")
        elif mode == "REMOTE_DNAT":
            args.append("--remote-proxy")
        else:
            args.append("--proxy")
        if cfg["proxy_host"]:
            args += ["--proxy-host", cfg["proxy_host"]]
        if cfg["proxy_port"]:
            args += ["--proxy-port", str(cfg["proxy_port"])]
        if cfg["proxy_type"]:
            args += ["--proxy-type", cfg["proxy_type"]]
        if cfg["proxy_user"]:
            args += ["--proxy-user", cfg["proxy_user"]]
        if cfg["proxy_pass"]:
            args += ["--proxy-pass", cfg["proxy_pass"]]

    if cfg["vpn"]:
        if cfg["vpn_interface"]:
            args += ["--vpn-interface", cfg["vpn_interface"]]
        else:
            args.append("--vpn")
            if cfg["vpn_config"]:
                args += [cfg["vpn_config"]]
        if cfg["vpn_creds"]:
            args += ["--vpn-creds", cfg["vpn_creds"]]

    if cfg["captive"]:
        args.append("--captive")
        if cfg["captive_port"]:
            args += ["--captive-port", str(cfg["captive_port"])]
        if cfg["captive_template"]:
            args += ["--captive-template", cfg["captive_template"]]

    return args


# ---------------------------------------------------------------------------
# Interfaces
# ---------------------------------------------------------------------------

_VIRTUAL_PREFIXES = ("tun", "tap", "veth", "virbr", "docker", "br-", "vlan", "bond", "dummy")


def list_interfaces() -> dict:
    wireless: list[str] = []
    ethernet: list[str] = []
    all_ifaces: list[str] = []

    try:
        names = sorted(os.listdir("/sys/class/net"))
    except OSError:
        names = []

    for name in names:
        if name == "lo":
            continue
        all_ifaces.append(name)
        base = os.path.join("/sys/class/net", name)
        is_wireless = os.path.exists(os.path.join(base, "wireless")) or name.startswith(("wl", "wlan"))
        has_device = os.path.exists(os.path.join(base, "device"))
        if is_wireless:
            wireless.append(name)
        elif has_device and not name.startswith(_VIRTUAL_PREFIXES):
            ethernet.append(name)

    return {"wireless": wireless, "ethernet": ethernet, "all": all_ifaces}


# ---------------------------------------------------------------------------
# Setup (.conf) read/write
# ---------------------------------------------------------------------------


def _ensure_dirs() -> None:
    for path in (SETUP_DIR, LOG_DIR, TMP_DIR):
        try:
            os.makedirs(path, exist_ok=True)
        except OSError:
            pass


def _safe_setup_path(name: str) -> str | None:
    name = os.path.basename(name.strip())
    if not name or name.startswith("."):
        return None
    if not name.endswith(".conf"):
        name += ".conf"
    return os.path.join(SETUP_DIR, name)


def list_setups() -> list[str]:
    _ensure_dirs()
    try:
        return sorted(f[:-5] for f in os.listdir(SETUP_DIR) if f.endswith(".conf"))
    except OSError:
        return []


def read_setup(name: str) -> dict | None:
    path = _safe_setup_path(name)
    if not path or not os.path.isfile(path):
        return None
    cfg = dict(FIELDS)
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            field = CONF_TO_FIELD.get(key)
            if not field:
                continue
            if field in BOOL_FIELDS:
                cfg[field] = value.lower() == "true"
            else:
                cfg[field] = value
    return cfg


def write_setup(name: str, cfg: dict) -> str:
    _ensure_dirs()
    path = _safe_setup_path(name)
    if not path:
        raise ValueError("Invalid setup name.")
    lines = ["# GhostAP Configuration File", ""]
    for key in sorted(CONF_KEYS.values()):
        field = CONF_TO_FIELD[key]
        value = cfg.get(field, FIELDS[field])
        if field in BOOL_FIELDS:
            value = "true" if value else "false"
        lines.append(f'{key}="{value}"')
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return os.path.basename(path)[:-5]


def delete_setup(name: str) -> bool:
    path = _safe_setup_path(name)
    if path and os.path.isfile(path):
        os.remove(path)
        return True
    return False


# ---------------------------------------------------------------------------
# Connected clients
# ---------------------------------------------------------------------------


def _read_leases() -> dict[str, tuple[str, str]]:
    leases: dict[str, tuple[str, str]] = {}
    try:
        with open(LEASE_FILE, "r", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 4:
                    continue
                mac = parts[1].lower()
                if not MAC_RE.match(mac):
                    continue
                ip, host = parts[2], parts[3]
                if host == "*":
                    host = ""
                leases[mac] = (ip, host)
    except OSError:
        pass
    return leases


def _fetch_stations(iface: str, ethernet: bool) -> tuple[dict, bool]:
    """Return ({mac: dict}, radio_available)."""
    if ethernet:
        return {}, False

    # hostapd_cli first (mirrors monitor.sh), then iw.
    if _which("hostapd_cli"):
        for extra in ([], ["-p", "/var/run/hostapd"]):
            raw = _capture(_run_prefix() + ["hostapd_cli", "-t", "2", *extra, "-i", iface, "all_sta"])
            if raw and "FAIL" not in raw:
                return _parse_hostapd(raw), True

    if _which("iw"):
        rc, raw = _capture_rc(_run_prefix() + ["iw", "dev", iface, "station", "dump"])
        if rc == 0:
            return _parse_iw(raw), True

    return {}, False


def _parse_hostapd(raw: str) -> dict:
    stations: dict[str, dict] = {}
    mac = None
    cur: dict = {}
    for line in raw.splitlines():
        line = line.rstrip("\r")
        if re.match(r"^\s*([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\s*$", line):
            if mac:
                stations[mac] = cur
            mac = line.strip().lower()
            cur = {}
            continue
        if mac and "=" in line:
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if key == "signal" and val.lstrip("-").isdigit():
                sig = int(val)
                if abs(sig) > 200:
                    sig //= 10
                cur["signal"] = sig
            elif key == "connected_time" and val.isdigit():
                cur["connected"] = int(val)
            elif key == "rx_bytes" and val.isdigit():
                cur["rx"] = int(val)
            elif key == "tx_bytes" and val.isdigit():
                cur["tx"] = int(val)
    if mac:
        stations[mac] = cur
    return stations


def _parse_iw(raw: str) -> dict:
    stations: dict[str, dict] = {}
    mac = None
    cur: dict = {}
    for line in raw.splitlines():
        line = line.rstrip("\r")
        m = re.match(r"^Station\s+([0-9a-fA-F:]+)", line)
        if m:
            if mac:
                stations[mac] = cur
            mac = m.group(1).lower()
            cur = {}
            continue
        if not mac:
            continue
        low = line.strip()
        if low.startswith("signal:"):
            digits = re.sub(r"[^0-9-]", "", low.split("signal:", 1)[1])
            if re.fullmatch(r"-?\d+", digits or ""):
                cur["signal"] = int(digits)
        elif low.startswith("connected time:"):
            digits = re.sub(r"[^0-9]", "", low.split("connected time:", 1)[1])
            if digits:
                cur["connected"] = int(digits)
        elif low.startswith("rx bytes:"):
            digits = re.sub(r"[^0-9]", "", low.split("rx bytes:", 1)[1])
            if digits:
                cur["rx"] = int(digits)
        elif low.startswith("tx bytes:"):
            digits = re.sub(r"[^0-9]", "", low.split("tx bytes:", 1)[1])
            if digits:
                cur["tx"] = int(digits)
    if mac:
        stations[mac] = cur
    return stations


def _read_neigh(iface: str) -> dict[str, tuple[str, str]]:
    """Return {mac: (ip, state)} for IPv4 neighbors on iface."""
    out: dict[str, tuple[str, str]] = {}
    rc, raw = _capture_rc(_run_prefix() + ["ip", "neigh", "show", "dev", iface])
    if rc != 0:
        return out
    for line in raw.splitlines():
        parts = line.split()
        if not parts or not IP_RE.match(parts[0]):
            continue
        ip = parts[0]
        mac = ""
        state = ""
        for i, tok in enumerate(parts):
            if tok == "lladdr" and i + 1 < len(parts):
                mac = parts[i + 1].lower()
            if tok in ("REACHABLE", "STALE", "DELAY", "PROBE", "PERMANENT", "FAILED", "NOARP"):
                state = tok
        if mac:
            out[mac] = (ip, state)
    return out


def get_clients(iface: str, ethernet: bool) -> list[dict]:
    if not iface:
        return []
    leases = _read_leases()
    neigh = _read_neigh(iface)
    stations, radio = _fetch_stations(iface, ethernet)

    seen: set[str] = set(leases) | set(neigh) | set(stations)
    online_states = {"REACHABLE", "DELAY", "PROBE", "STALE", "PERMANENT"}

    clients: list[dict] = []
    for mac in seen:
        lease = leases.get(mac)
        ip = lease[0] if lease else (neigh[mac][0] if mac in neigh else "")
        hostname = lease[1] if lease else ""
        sta = stations.get(mac, {})
        if mac in stations:
            status = "Online"
        elif not radio and mac in neigh and neigh[mac][1] in online_states:
            status = "Online"
        elif mac in stations or mac in neigh:
            status = "Leaving"
        else:
            status = "Stale"
        clients.append(
            {
                "mac": mac,
                "ip": ip,
                "hostname": hostname,
                "signal": sta.get("signal"),
                "connected": sta.get("connected"),
                "rx": sta.get("rx", 0),
                "tx": sta.get("tx", 0),
                "status": status,
            }
        )

    clients.sort(key=lambda c: (c["signal"] is None, -(c["signal"] or 0), c["mac"]))
    return clients


# ---------------------------------------------------------------------------
# Nearby AP scan
# ---------------------------------------------------------------------------

SCAN_HEADER_RE = re.compile(r"BSSID\s+SSID\s+CH\s+SEC\s+SIGNAL")


def run_scan(iface: str, duration: int) -> dict:
    if not iface:
        return {"error": "No interface selected."}
    if not _which("airodump-ng"):
        return {"error": "airodump-ng not installed (install the aircrack-ng package)."}

    duration = max(3, min(int(duration), 60))
    cmd = _run_prefix() + ["bash", GHOSTAP_SH, "-i", iface, "--scan-aps", str(duration)]
    try:
        proc = subprocess.run(
            cmd,
            cwd=REPO_DIR,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=duration + 60,
        )
    except subprocess.TimeoutExpired:
        return {"error": "Scan timed out."}
    except OSError as exc:
        return {"error": f"Failed to run scan: {exc}"}

    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    aps = _parse_scan_table(text)
    return {"access_points": aps, "duration": duration}


def _parse_scan_table(text: str) -> list[dict]:
    lines = text.splitlines()
    header_idx = None
    cols: dict[str, int] = {}
    for i, line in enumerate(lines):
        if SCAN_HEADER_RE.search(line):
            # Find each token *after* the previous one: a naive line.find("SSID")
            # would match the "SSID" inside "BSSID".
            p = line.find("BSSID")
            cols["bssid"] = p
            p = line.find("SSID", p + len("BSSID"))
            cols["ssid"] = p
            p = line.find("CH", p + len("SSID"))
            cols["ch"] = p
            p = line.find("SEC", p + len("CH"))
            cols["sec"] = p
            p = line.find("SIGNAL", p + len("SEC"))
            cols["signal"] = p
            if all(v >= 0 for v in cols.values()):
                header_idx = i
                break
    if header_idx is None:
        return []

    aps: list[dict] = []
    for line in lines[header_idx + 1:]:
        if not line.strip() or set(line.strip()) <= {"-"}:
            continue
        if not re.match(r"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}", line):
            continue
        chunk = line
        bssid = chunk[cols["bssid"]:cols["ssid"]].strip()
        ssid = chunk[cols["ssid"]:cols["ch"]].strip()
        ch = chunk[cols["ch"]:cols["sec"]].strip()
        sec = chunk[cols["sec"]:cols["signal"]].strip()
        sig = chunk[cols["signal"]:].strip()
        if not MAC_RE.match(bssid):
            continue
        aps.append({"bssid": bssid, "ssid": ssid or "<hidden>", "channel": ch, "security": sec, "signal": sig})
    return aps


# ---------------------------------------------------------------------------
# Small subprocess helpers
# ---------------------------------------------------------------------------


def _which(name: str) -> bool:
    from shutil import which

    return which(name) is not None


def _capture_rc(cmd: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def _capture(cmd: list[str]) -> str:
    return _capture_rc(cmd)[1]


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

BUS = LogBus()
MANAGER = APManager(BUS)

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "GhostAP-GUI"

    # -- utility -----------------------------------------------------------
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if os.environ.get("GHOSTAP_GUI_DEBUG"):
            sys.stderr.write("[http] " + (fmt % args) + "\n")

    def _send_json(self, obj, status: int = 200) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text: str, status: int = 200, content_type: str = "text/plain") -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    def _serve_static(self, path: str) -> None:
        if path in ("/", "/index.html"):
            rel = "index.html"
        else:
            rel = unquote(path[len("/static/"):]) if path.startswith("/static/") else path.lstrip("/")
        target = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if os.path.commonpath([target, STATIC_DIR]) != STATIC_DIR or not os.path.isfile(target):
            self._send_text("Not found", 404)
            return
        ext = os.path.splitext(target)[1].lower()
        with open(target, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # -- GET ---------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith("/api/"):
            self._handle_get_api(path)
        elif path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self._serve_static(path)

    def _handle_get_api(self, path: str) -> None:
        if path == "/api/status":
            self._send_json(MANAGER.status())
        elif path == "/api/interfaces":
            self._send_json(list_interfaces())
        elif path == "/api/config":
            self._send_json({"fields": FIELDS, "defaults": dict(FIELDS)})
        elif path == "/api/setups":
            self._send_json({"setups": list_setups()})
        elif path.startswith("/api/setups/"):
            name = unquote(path[len("/api/setups/"):])
            cfg = read_setup(name)
            if cfg is None:
                self._send_json({"error": "Setup not found."}, 404)
            else:
                self._send_json({"name": name, "config": cfg})
        elif path == "/api/logs/recent":
            self._send_json({"lines": BUS.recent()})
        elif path == "/api/logs":
            self._stream_logs()
        elif path == "/api/clients":
            status = MANAGER.status()
            cfg = status.get("config") or {}
            iface = cfg.get("interface") or _guess_interface()
            ethernet = bool(cfg.get("ethernet_mode"))
            self._send_json({"clients": get_clients(iface, ethernet), "interface": iface})
        else:
            self._send_json({"error": "Unknown endpoint."}, 404)

    def _stream_logs(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        q = BUS.subscribe()
        try:
            for line in BUS.recent(200):
                self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
            self.wfile.flush()
            while True:
                try:
                    line = q.get(timeout=15)
                    self.wfile.write(f"data: {line}\n\n".encode("utf-8"))
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            BUS.unsubscribe(q)

    # -- POST --------------------------------------------------------------
    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if not path.startswith("/api/"):
            self._send_text("Not found", 404)
            return
        self._handle_post_api(path)

    def _handle_post_api(self, path: str) -> None:
        if path == "/api/start":
            cfg = _norm_config(self._read_json())
            errors = validate_config(cfg)
            if errors:
                self._send_json({"error": " ".join(errors), "errors": errors}, 400)
                return
            ok, msg = MANAGER.start(cfg)
            self._send_json({"ok": ok, "message": msg}, 200 if ok else 409)
        elif path == "/api/stop":
            ok, msg = MANAGER.stop()
            self._send_json({"ok": ok, "message": msg}, 200 if ok else 409)
        elif path == "/api/scan":
            data = self._read_json()
            iface = str(data.get("interface") or "").strip()
            duration = data.get("duration", 12)
            try:
                duration = int(duration)
            except (TypeError, ValueError):
                duration = 12
            result = run_scan(iface, duration)
            self._send_json(result, 200 if "error" not in result else 400)
        elif path.startswith("/api/setups/"):
            name = unquote(path[len("/api/setups/"):])
            cfg = _norm_config(self._read_json())
            try:
                saved = write_setup(name, cfg)
            except ValueError as exc:
                self._send_json({"error": str(exc)}, 400)
                return
            self._send_json({"ok": True, "name": saved})
        else:
            self._send_json({"error": "Unknown endpoint."}, 404)

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith("/api/setups/"):
            name = unquote(path[len("/api/setups/"):])
            ok = delete_setup(name)
            self._send_json({"ok": ok}, 200 if ok else 404)
        else:
            self._send_json({"error": "Unknown endpoint."}, 404)


def _guess_interface() -> str:
    ifaces = list_interfaces()
    if ifaces["wireless"]:
        return ifaces["wireless"][0]
    if ifaces["ethernet"]:
        return ifaces["ethernet"][0]
    return ""


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="GhostAP Web GUI")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8787, help="Bind port (default 8787)")
    args = parser.parse_args()

    if not os.path.isfile(GHOSTAP_SH):
        sys.stderr.write(f"Error: GhostAP.sh not found at {GHOSTAP_SH}\n")
        return 1

    _ensure_dirs()
    BUS.seed_from_file(LOG_FILE, limit=200)

    if USE_SUDO:
        sys.stderr.write(
            "Warning: not running as root. Starting/stopping the AP will use\n"
            "         'sudo -n', which fails unless your sudo credentials are\n"
            "         cached. Prefer: sudo ./gui/run.sh\n"
        )

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    url = f"http://{args.host}:{args.port}/"
    print(f"GhostAP GUI listening on {url}")
    print(f"  GhostAP script : {GHOSTAP_SH}")
    print(f"  Setups         : {SETUP_DIR}")
    print("Press Ctrl+C to stop the GUI (this also stops a running AP).")

    def _shutdown(signum, _frame):
        print("\nShutting down GUI...")
        try:
            MANAGER.stop()
        except Exception:  # noqa: BLE001
            pass
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        _shutdown(signal.SIGINT, None)
    finally:
        try:
            MANAGER.stop()
        except Exception:  # noqa: BLE001
            pass
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
