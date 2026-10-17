#!/bin/bash
# disk2glance installer.
#
# Offline (bundle already on the VM disk):
#   tar xzf disk2glance-<ver>.tar.gz && cd disk2glance-<ver> && sudo ./install.sh
# Online (downloads the bundle):
#   curl -fsSL <url>/install.sh | sudo D2G_BUNDLE_URL=<url>/disk2glance-<ver>.tar.gz bash
#
# Options:
#   --openrc FILE   copy OpenStack credentials to /etc/disk2glance/openrc (mode 600)
#   --props FILE    copy image properties JSON to /etc/disk2glance/props.json
#   --build         if no prebuilt module matches the kernel, build one here (needs gcc, make, kernel headers)
#   --uninstall     remove everything installed (config kept unless --purge)
#   --purge         with --uninstall: also remove /etc/disk2glance
set -euo pipefail
PREFIX=/opt/disk2glance
CONF=/etc/disk2glance
OPENRC= PROPSF= BUILD=0 UNINSTALL=0 PURGE=0
while [ $# -gt 0 ]; do
  case $1 in
    --openrc) OPENRC=$2; shift ;;
    --props) PROPSF=$2; shift ;;
    --build) BUILD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
log() { echo "[disk2glance] $*"; }
warn() { echo "[disk2glance] WARNING: $*" >&2; }
die() { echo "[disk2glance] ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
KVER=$(uname -r)

# --- uninstall -------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  if [ -e /proc/datto-info ]; then
    if grep -q '"minor"' /proc/datto-info; then die "dattobd has active snapshots — run 'dbdctl destroy <minor>' first"; fi
    rmmod dattobd && log "dattobd unloaded"
  fi
  # (no 'semanage -l | grep -q' test: with pipefail grep's early exit makes it false)
  command -v semanage >/dev/null && semanage fcontext -d "$PREFIX/modules(/.*)?" 2>/dev/null || true
  if [ -f /etc/systemd/system/disk2rx-agent.service ]; then
    systemctl disable -q --now disk2rx-agent.service 2>/dev/null || true
    rm -f /etc/systemd/system/disk2rx-agent.service /etc/needrestart/conf.d/disk2rx.conf; systemctl daemon-reload
  fi
  rm -rf "$PREFIX" /usr/local/sbin/disk2glance /usr/local/sbin/disk2s3 /usr/local/sbin/disk2rx /run/disk2glance /run/disk2s3 /run/disk2rx /var/log/disk2glance.log /var/log/disk2s3.log /var/log/disk2rx.log
  for c in disk2glance disk2s3 disk2rx; do [ "$(readlink /usr/sbin/$c 2>/dev/null)" = "$PREFIX/bin/$c" ] && rm -f /usr/sbin/$c; done
  # leftovers of a run killed with -9: COW file and the first-boot unit meant for the copy
  rm -f /.datto_d2g /boot/.datto_d2g /etc/systemd/system/disk2glance-cowclean.service \
    /etc/systemd/system/multi-user.target.wants/disk2glance-cowclean.service
  [ "$PURGE" = 1 ] && rm -rf "$CONF" && log "config removed"
  log "uninstalled"
  exit 0
fi

# --- locate bundle (this dir, or download) ----------------------------------------
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)
if [ -f "$SELF_DIR/VERSION" ] && [ -d "$SELF_DIR/bin" ]; then
  B=$SELF_DIR
else
  [ -n "${D2G_BUNDLE_URL:-}" ] || die "not run from a bundle dir and D2G_BUNDLE_URL is not set"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  log "downloading $D2G_BUNDLE_URL"
  curl -fsSL -o "$TMP/b.tgz" "$D2G_BUNDLE_URL"
  if curl -fsSL -o "$TMP/b.tgz.sha256" "$D2G_BUNDLE_URL.sha256" 2>/dev/null; then
    (cd "$TMP" && echo "$(cut -d' ' -f1 b.tgz.sha256)  b.tgz" | sha256sum -c - >/dev/null) || die "bundle checksum mismatch"
    log "bundle sha256 OK"
  else warn "no $D2G_BUNDLE_URL.sha256 — bundle not verified"; fi
  tar xzf "$TMP/b.tgz" -C "$TMP"
  B=$(dirname "$(ls -d "$TMP"/*/VERSION | head -1)")
fi
VER=$(cat "$B/VERSION")
log "installing disk2glance $VER for kernel $KVER"

# --- environment checks ------------------------------------------------------------
[ "$(uname -m)" = x86_64 ] || die "only x86_64 is supported"
for c in curl dd findmnt flock md5sum sha512sum tee insmod rmmod stat; do
  command -v $c >/dev/null || die "required command '$c' not found"
done
sb=$(mokutil --sb-state 2>/dev/null || true)
if [[ "${sb,,}" == *"secureboot enabled"* ]]; then
  warn "Secure Boot is enabled: an unsigned dattobd module will not load (sign it with a MOK key or disable SB)"
fi
# answers in the system language: ENABLED/DISABLED or ВКЛЮЧЕНО/ВЫКЛЮЧЕНО
zps=$(astra-digsig-control is-enabled 2>/dev/null || true)
if [ "$zps" = 1 ] || [[ "${zps^^}" == ENABLED* ]] || [ "$zps" = ВКЛЮЧЕНО ]; then
  warn "Astra Linux closed software environment (ZPS/digsig) is on: unsigned modules and binaries will be blocked"
fi
if [ -r /sys/kernel/security/lockdown ] && grep -q '\[integrity\]\|\[confidentiality\]' /sys/kernel/security/lockdown; then
  warn "kernel lockdown is active: unsigned modules will not load"
fi

# --- module for this kernel -------------------------------------------------------
KO_SRC="$B/modules/$KVER/dattobd.ko"
if [ -f "$KO_SRC" ]; then
  (cd "$(dirname "$KO_SRC")" && sha256sum -c dattobd.ko.sha256 >/dev/null) || die "module checksum mismatch"
  vm=$(modinfo -F vermagic "$KO_SRC" | awk '{print $1}')
  [ "$vm" = "$KVER" ] || die "module vermagic $vm != running kernel $KVER"
  log "prebuilt module found for $KVER"
elif [ "$BUILD" = 1 ]; then
  [ -d "$B/src/dattobd" ] || die "bundle has no dattobd source"
  [ -d "/lib/modules/$KVER/build" ] || die "kernel headers for $KVER not installed (kernel-devel / linux-headers)"
  command -v gcc >/dev/null && command -v make >/dev/null || die "gcc/make not installed"
  log "building dattobd for $KVER (as root; genconfig needs /boot/System.map)"
  BTMP=$(mktemp -d); cp -r "$B/src/dattobd" "$BTMP/"
  make -C "$BTMP/dattobd" driver >"$BTMP/build.log" 2>&1 || { tail -20 "$BTMP/build.log"; die "module build failed"; }
  mkdir -p "$B/modules/$KVER"; cp "$BTMP/dattobd/src/dattobd.ko" "$B/modules/$KVER/"
  strip --strip-debug "$B/modules/$KVER/dattobd.ko" 2>/dev/null || true
  (cd "$B/modules/$KVER" && sha256sum dattobd.ko > dattobd.ko.sha256)
  rm -rf "$BTMP"
  KO_SRC="$B/modules/$KVER/dattobd.ko"
else
  die "no prebuilt dattobd module for kernel $KVER. Available: $(ls "$B/modules" | tr '\n' ' ')
  Options: build one on a builder VM (docs/build-modules.md) and add it to the bundle, or rerun with --build."
fi

# --- install -----------------------------------------------------------------------
install -d -m755 "$PREFIX" "$PREFIX/bin" "$PREFIX/modules/$KVER"
install -m755 "$B/disk2glance.sh" "$PREFIX/bin/disk2glance"
[ -f "$B/disk2s3.sh" ] && install -m755 "$B/disk2s3.sh" "$PREFIX/bin/disk2s3"   # experimental S3 mode
[ -f "$B/disk2rx.sh" ] && install -m755 "$B/disk2rx.sh" "$PREFIX/bin/disk2rx"   # experimental: to a d2g receiver
install -m755 "$B/bin/dbdctl" "$B/bin/update-img" "$B/bin/jq" "$PREFIX/bin/"
install -m644 "$KO_SRC" "$(dirname "$KO_SRC")/dattobd.ko.sha256" "$PREFIX/modules/$KVER/"
install -m644 "$B/VERSION" "$PREFIX/VERSION"
install -m755 "$B/install.sh" "$PREFIX/install.sh"   # for --uninstall after the bundle dir is gone
# SELinux (RED OS, CentOS): a module file labelled usr_t can be loaded from a login shell but
# not from a systemd service (disk2glance --detach) -> label the modules dir modules_object_t
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  if command -v semanage >/dev/null; then
    semanage fcontext -a -t modules_object_t "$PREFIX/modules(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t modules_object_t "$PREFIX/modules(/.*)?" 2>/dev/null || true
    restorecon -R "$PREFIX/modules"
  else
    chcon -R -t modules_object_t "$PREFIX/modules"
  fi
  log "SELinux: $PREFIX/modules labelled modules_object_t"
fi
for c in disk2glance disk2s3 disk2rx; do
  [ -f "$PREFIX/bin/$c" ] || continue
  ln -sf "$PREFIX/bin/$c" /usr/local/sbin/$c
  # sudo secure_path on RHEL-likes has no /usr/local/sbin
  [ -e /usr/sbin/$c ] || ln -s "$PREFIX/bin/$c" /usr/sbin/$c
done
install -d -m700 "$CONF" "$PREFIX/examples"
install -m644 "$B"/examples/* "$PREFIX/examples/"

# credentials: copy the given file, or leave a template to fill in
if [ -n "$OPENRC" ]; then
  grep -qE '^[[:space:]]*read[[:space:]]' "$OPENRC" && warn "$OPENRC asks for the password interactively ('read ...'): edit $CONF/openrc, put export OS_PASSWORD='...' and remove the prompt"
  install -m600 "$OPENRC" "$CONF/openrc" && log "credentials: $OPENRC -> $CONF/openrc"
elif [ ! -f "$CONF/openrc" ]; then
  install -m600 "$B/examples/openrc.example" "$CONF/openrc"
  TODO_OPENRC=1
fi

# image properties: copy the given file, or pick the example for this OS
if [ -n "$PROPSF" ]; then
  install -m644 "$PROPSF" "$CONF/props.json" && log "image properties: $PROPSF -> $CONF/props.json"
elif [ ! -f "$CONF/props.json" ]; then
  . /etc/os-release
  case "$ID:${VERSION_ID:-}" in
    ubuntu:24.04*) ex=ubuntu-24.04 ;;
    redos:8*)      ex=redos-8 ;;
    redos:7.3*)    ex=redos-7.3 ;;
    centos:7*)     ex=centos-7 ;;
    astra:1.7*)    ex=astra-1.7 ;;
    astra:1.8*)    ex=astra-1.8 ;;
    *)             ex=linux ;;
  esac
  install -m644 "$B/examples/props-$ex.json" "$CONF/props.json"
  log "image properties: example props-$ex.json -> $CONF/props.json (check it)"
fi

# options file
[ -f "$CONF/disk2glance.conf" ] || install -m644 "$B/examples/disk2glance.conf.example" "$CONF/disk2glance.conf"

# --- self-test: load and unload the module ------------------------------------------
if [ -e /proc/datto-info ]; then
  log "dattobd already loaded ($(grep -o '"version": "[^"]*"' /proc/datto-info))"
else
  insmod "$PREFIX/modules/$KVER/dattobd.ko" || die "insmod failed — see dmesg"
  rmmod dattobd
  log "module load test OK"
fi
log "installed to $PREFIX (module is NOT loaded at boot; disk2glance loads it only while running)"
log "config: $CONF/openrc (credentials), $CONF/props.json (image properties), $CONF/disk2glance.conf (options)"
if [ "${TODO_OPENRC:-0}" = 1 ]; then
  log "NEXT: fill in the credentials template: $CONF/openrc  (see docs/quickstart.md, step 4)"
fi
log "then: sudo disk2glance --check   and   sudo disk2glance --detach --name <image-name>"
