#!/bin/bash
# Build dattobd.ko for a given kernel version on a BUILDER VM of the same distro
# (the builder does not have to run that kernel). Output: modules/<kver>/dattobd.ko
#
# Usage (root): build-module.sh <kernel-version> [<kernel-version>...]
#   e.g. build-module.sh 6.12.92-1.red80.x86_64 6.8.0-134-generic
# Needs: gcc, make, dkms, dattobd source in $SRC (default /root/dattobd, tag $V).
set -euo pipefail
V=${V:-0.12.2}
SRC=${SRC:-/root/dattobd}
OUT=${OUT:-$PWD/modules}
log() { echo "$(date -u +%T) $*" >&2; }

[ -d "$SRC" ] || git clone -q --branch v$V https://github.com/datto/dattobd.git "$SRC"

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

mkdir -p /usr/src/dattobd-$V
cp -r "$SRC"/src/* /usr/src/dattobd-$V/
sed "s/@MODULE_VERSION@/$V/" "$SRC/dist/dattobd-dkms-conf" > /usr/src/dattobd-$V/dkms.conf
[ -d /var/lib/dkms/dattobd/$V ] || dkms add dattobd/$V >/dev/null

for k in "$@"; do
  log "== $k"
  prep_headers "$k"
  dkms build dattobd/$V -k "$k" --force >/tmp/build-$k.log 2>&1 || { tail -20 /tmp/build-$k.log; exit 1; }
  ko=$(find /var/lib/dkms/dattobd/$V/"$k" -name 'dattobd.ko*' | head -1)
  mkdir -p "$OUT/$k"
  case $ko in *.zst) zstd -qdc "$ko";; *.xz) xz -dc "$ko";; *) cat "$ko";; esac > "$OUT/$k/dattobd.ko"
  strip --strip-debug "$OUT/$k/dattobd.ko"
  (cd "$OUT/$k" && sha256sum dattobd.ko > dattobd.ko.sha256)
  log "   $(modinfo -F vermagic "$OUT/$k/dattobd.ko") -> $OUT/$k/dattobd.ko"
done
