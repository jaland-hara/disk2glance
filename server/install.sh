#!/bin/bash
# Install the d2g server from this bundle (Ubuntu 22.04+/Debian 12+, Python 3.10+).
#   ./install.sh --role orch [options]   orchestrator: nginx (SNI on :443), d2g-orch.service; without
#                                        /etc/d2g/openrc it starts the web setup wizard (d2g bootstrap
#                                        [--public-ip IP] [--ui-allow CIDR]), else runs d2g setup [options]
#   ./install.sh --role rx                         receiver (run by cloud-init): unique-boot, join, d2g-rx.service
#   ./install.sh --uninstall
# Cloud credentials of the orchestrator: /etc/d2g/openrc (600), filled before 'd2g setup'.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"
B=$(pwd); VER=$(cat VERSION)
log() { echo "install: $*"; }
ROLE=
case ${1:-} in
  --role) ROLE=$2; shift 2 ;;
  --uninstall)
    systemctl disable --now d2g-orch d2g-rx 2>/dev/null || true
    rm -f /etc/systemd/system/d2g-orch.service /etc/systemd/system/d2g-rx.service /usr/local/sbin/d2g
    rm -rf /opt/d2g
    sed -i '/d2g-stream.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
    rm -f /etc/nginx/d2g-stream.conf; systemctl reload nginx 2>/dev/null || true
    systemctl daemon-reload; log "removed (data and keys kept in /etc/d2g and /var/lib/d2g)"; exit 0 ;;
  *) echo "usage: $0 --role orch|rx [setup options] | --uninstall" >&2; exit 64 ;;
esac

install -d -m 755 /opt/d2g /opt/d2g/pkg /etc/d2g
install -d -m 700 /var/lib/d2g
rm -rf /opt/d2g/d2g && cp -r d2g /opt/d2g/ && find /opt/d2g/d2g -name __pycache__ -prune -exec rm -rf {} +
install -m 755 unique-boot.sh /opt/d2g/unique-boot.sh
install -m 644 VERSION /opt/d2g/VERSION
# not "python3 -m d2g": that imports the package from the current directory first
cat >/usr/local/sbin/d2g <<'WRAP'
#!/bin/sh
exec python3 -c 'import sys; sys.path.insert(0, "/opt/d2g"); from d2g.__main__ import main; sys.exit(main())' "$@"
WRAP
chmod 755 /usr/local/sbin/d2g

case $ROLE in
orch)
  if ! dpkg -s nginx-core libnginx-mod-stream >/dev/null 2>&1; then
    log "installing nginx (stream module)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx-core libnginx-mod-stream >/dev/null
  fi
  rm -f /etc/nginx/sites-enabled/default
  [ -f /etc/nginx/d2g-stream.conf ] || : >/etc/nginx/d2g-stream.conf
  grep -q d2g-stream.conf /etc/nginx/nginx.conf || echo 'stream { include /etc/nginx/d2g-stream.conf; }' >>/etc/nginx/nginx.conf
  # packages the orchestrator hands out: the agent bundle and this server bundle (for receivers)
  rm -f /opt/d2g/pkg/*.tar.gz
  cp pkg/*.tar.gz /opt/d2g/pkg/
  tar czf "/opt/d2g/pkg/d2g-server-$VER.tar.gz" -C "$(dirname "$B")" "$(basename "$B")"
  install -m 644 d2g-orch.service /etc/systemd/system/d2g-orch.service
  systemctl daemon-reload
  install -m 644 d2g-rx.service /etc/systemd/system/d2g-rx.service
  systemctl daemon-reload
  if [ ! -s /etc/d2g/openrc ] && ! { [ -f /etc/d2g/orch.json ] && ! grep -q '"setup_mode": true' /etc/d2g/orch.json; }; then
    # no cloud credentials yet: start in setup mode, the rest is done in the web wizard
    d2g bootstrap "$@"
    systemctl enable -q d2g-orch && systemctl restart d2g-orch
    systemctl reload-or-restart nginx
    exit 0
  fi
  d2g setup "$@"
  systemctl daemon-reload
  systemctl enable -q d2g-orch && systemctl restart d2g-orch
  if [ -f /etc/d2g/rx.json ]; then
    # the local receiver rx0: job volumes are attached to this VM — its own disk must not look like them
    /opt/d2g/unique-boot.sh
    systemctl enable -q d2g-rx && systemctl restart d2g-rx
  fi
  log "orchestrator $VER is running: d2g status"
  ;;
rx)
  # job volumes are copies of source disks: the receiver's own disk must not look like them at boot
  /opt/d2g/unique-boot.sh
  [ -f /etc/d2g/rx.json ] || d2g rx-join
  install -m 644 d2g-rx.service /etc/systemd/system/d2g-rx.service
  systemctl daemon-reload
  systemctl enable -q d2g-rx && systemctl restart d2g-rx
  log "receiver $VER is running"
  ;;
*) echo "unknown role $ROLE" >&2; exit 64 ;;
esac
