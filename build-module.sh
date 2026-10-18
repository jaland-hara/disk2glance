#!/bin/bash
# Build dattobd.ko for a given kernel version on a BUILDER VM of the same distro
# (the builder does not have to run that kernel). Output: modules/<kver>/dattobd.ko
#
# Usage (root): build-module.sh <kernel-version> [<kernel-version>...]
#   e.g. build-module.sh 6.12.92-1.red80.x86_64 6.8.0-134-generic
# Needs: gcc, make, git, elfutils-libelf-devel; dattobd source in $SRC (default /root/dattobd, tag $V).
# No dkms needed: genconfig.sh + kbuild are run directly, as root.
# patches/*.patch next to this script (or in $PATCHES) are applied to the build copy (patch -p2).
set -euo pipefail
V=${V:-0.12.2}
SRC=${SRC:-/root/dattobd}
OUT=${OUT:-$PWD/modules}
PATCHES=${PATCHES:-$(cd "$(dirname "$0")" && pwd)/patches}
log() { echo "$(date -u +%T) $*" >&2; }

[ -d "$SRC" ] || git -c advice.detachedHead=false clone -q --branch v$V https://github.com/datto/dattobd.git "$SRC"

prep_headers() { # kver: headers + System.map for genconfig
  local k=$1
  if command -v dnf >/dev/null || command -v yum >/dev/null; then
    local pm; pm=$(command -v dnf || command -v yum)
    local base=${k%.x86_64}
    if [ ! -d "/usr/src/kernels/$k" ]; then
      $pm -y -q install "kernel-lt-devel-$base" >/dev/null 2>&1 || $pm -y -q install "kernel-devel-$base" >/dev/null
    fi
    # kernel-devel ships System.map; genconfig looks in /boot or /lib/modules/<k>
    [ -f "/boot/System.map-$k" ] || cp "/usr/src/kernels/$k/System.map" "/boot/System.map-$k"
    # kernel not installed on the builder -> no /lib/modules/<k>/build link
    if [ ! -e "/lib/modules/$k/build" ]; then
      mkdir -p "/lib/modules/$k"; ln -s "/usr/src/kernels/$k" "/lib/modules/$k/build"
    fi
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-headers-$k" >/dev/null
    if [ ! -f "/boot/System.map-$k" ]; then
      local tmp; tmp=$(mktemp -d)
      (cd "$tmp" && apt-get download -qq "linux-modules-$k" >/dev/null && dpkg-deb --fsys-tarfile linux-modules-"$k"_*.deb \
        | tar -x ./boot/System.map-"$k" && cp "boot/System.map-$k" /boot/)
      rm -rf "$tmp"
    fi
  fi
  [ -d "/lib/modules/$k/build" ] || { log "no headers for $k"; return 1; }
}

for k in "$@"; do
  log "== $k"
  prep_headers "$k"
  # same steps as dattobd's dkms.conf (PRE_BUILD genconfig.sh + kbuild), without needing dkms
  B=$(mktemp -d); cp -r "$SRC"/src/. "$B/"
  for p in "$PATCHES"/*.patch; do [ -f "$p" ] || continue; patch -s -d "$B" -p2 <"$p" || { log "patch $p failed"; exit 1; }; log "   applied $(basename "$p")"; done
  ( cd "$B" && make clean >/dev/null 2>&1 || true
    ./genconfig.sh "$k" && make -C "/lib/modules/$k/build" M="$B" KVER="$k" modules ) >/tmp/build-$k.log 2>&1 \
    || { tail -20 /tmp/build-$k.log; exit 1; }
  mkdir -p "$OUT/$k"
  cp "$B/dattobd.ko" "$OUT/$k/dattobd.ko"
  strip --strip-debug "$OUT/$k/dattobd.ko"
  (cd "$OUT/$k" && sha256sum dattobd.ko > dattobd.ko.sha256)
  log "   $(modinfo -F vermagic "$OUT/$k/dattobd.ko") -> $OUT/$k/dattobd.ko"
  rm -rf "$B"
done
