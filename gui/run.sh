#!/usr/bin/env bash
# Launch the GhostAP web GUI. The AP needs root, so this re-execs under sudo.
# Extra arguments (e.g. --port 9000) are forwarded to server.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="${SCRIPT_DIR}/server.py"

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo python3 "${SERVER}" "$@"
fi

exec python3 "${SERVER}" "$@"
