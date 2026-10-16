#!/bin/bash
# Install the d2g server (stage 1: orchestrator + receiver on one VM, Ubuntu 24.04).
# Usage: sudo ./install.sh --name rx01.d2g --ip <grey IP> [--ip <FIP>] [d2g init options]
# Cloud credentials go to /etc/d2g/openrc (600) before the first 'd2g job new'.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"
install -d -m 755 /opt/d2g /etc/d2g
install -m 755 d2g.py /opt/d2g/d2g.py
ln -sf /opt/d2g/d2g.py /usr/local/sbin/d2g
install -m 644 d2g.service /etc/systemd/system/d2g.service
[ -f /etc/d2g/d2g.json ] || /opt/d2g/d2g.py init "$@"
[ -f /etc/d2g/openrc ] || { install -m 600 /dev/null /etc/d2g/openrc; echo "fill /etc/d2g/openrc (OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_ID, OS_USER_DOMAIN_NAME, OS_REGION_NAME)"; }
systemctl daemon-reload
systemctl enable --now d2g.service
systemctl restart d2g.service
systemctl --no-pager -l status d2g.service | head -5
