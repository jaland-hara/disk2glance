#!/bin/bash
# One-command install of the d2g orchestrator (Ubuntu 22.04+/Debian 12+ VM in the target project):
#   curl -fsSL https://github.com/jaland-hara/disk2glance/releases/latest/download/d2g-server-install.sh | sudo bash
#   ... | sudo bash -s -- [--version 0.9.0] [--bundle FILE] [--public-ip IP] [--ui-allow CIDR]...
# Downloads d2g-server-<version>.tar.gz from GitHub Releases, checks its SHA-256 and runs
# install.sh --role orch. Without cloud credentials it starts the web setup wizard and prints its
# address, a one-time code and the certificate fingerprint.
set -euo pipefail
REPO=${REPO:-jaland-hara/disk2glance}
VER= BUNDLE=
ARGS=()
while [ $# -gt 0 ]; do
  case $1 in
    --version) VER=${2#v}; shift ;;
    --bundle) BUNDLE=$2; shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
log() { echo "d2g-server-install: $*"; }
die() { echo "d2g-server-install: ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (| sudo bash)"
command -v python3 >/dev/null || die "python3 is required"
command -v curl >/dev/null || die "curl is required"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
if [ -z "$BUNDLE" ]; then
  if [ -z "$VER" ]; then
    VER=$(curl -fsS "https://api.github.com/repos/$REPO/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))') \
      || die "cannot find the latest release of $REPO"
  fi
  url="https://github.com/$REPO/releases/download/v$VER"
  log "downloading d2g-server-$VER from $url"
  curl -fsSL -o "$D/d2g-server-$VER.tar.gz" "$url/d2g-server-$VER.tar.gz" || die "download failed"
  curl -fsSL -o "$D/d2g-server-$VER.tar.gz.sha256" "$url/d2g-server-$VER.tar.gz.sha256" || die "checksum download failed"
  (cd "$D" && sha256sum -c "d2g-server-$VER.tar.gz.sha256" >/dev/null) || die "checksum mismatch"
  BUNDLE=$D/d2g-server-$VER.tar.gz
  log "checksum OK"
fi
mkdir -p /opt/d2g-src
tar xzf "$BUNDLE" -C /opt/d2g-src
top=$(tar tzf "$BUNDLE" | sed -n '1p')   # sed reads all input: no SIGPIPE for tar under pipefail
dir=/opt/d2g-src/${top%%/*}
[ -x "$dir/install.sh" ] || die "no install.sh in $BUNDLE"
command -v apt-get >/dev/null && { apt-get update -qq >/dev/null 2>&1 || true; }
exec "$dir/install.sh" --role orch ${ARGS[@]+"${ARGS[@]}"}
