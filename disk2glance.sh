#!/bin/bash
# disk2glance — stream a live Linux disk into an OpenStack Glance image (raw), no temp files.
#
# Mounted ext4/ext3/xfs filesystems — on partitions or on linear LVM volumes — are
# read from dattobd copy-on-write snapshots (crash-consistent, taken back to back);
# everything else (partition table, BIOS boot, EFI, swap, LVM metadata, free
# extents, gaps, GPT backup) is read straight from the disk.
#
# Usage: disk2glance [--check] [--detach] [--name NAME] [--openrc FILE] [--props FILE]
#                    [--config FILE] [--disk /dev/vda] [--cow-mb N] [--keep-module]
#   --check        preflight only: config files, auth, Glance endpoint, layout, module load; no upload
#   --openrc FILE  cloud credentials (OS_* variables)      default: /etc/disk2glance/openrc
#   --props FILE   image properties (JSON)                 default: /etc/disk2glance/props.json
#   --config FILE  defaults for these options (KEY=value)  default: /etc/disk2glance/disk2glance.conf
#   --detach       run as a transient systemd unit (survives logout / logind KillUserProcesses);
#                  log: /var/log/disk2glance.log
#   --cow-mb N     COW file size per snapshot in MiB (default: dattobd's 10% of the volume);
#                  smaller = shorter write pause at snapshot time on busy disks, but overflows sooner
#   --keep-module  leave dattobd loaded afterwards (default: unload if we loaded it)
# Command-line options override the config file.
set -euo pipefail
PREFIX=${PREFIX:-/opt/disk2glance}
export PATH=$PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VERSION=$(cat "$PREFIX/VERSION" 2>/dev/null || echo dev)

# defaults, then the config file, then command-line options
DISK=/dev/vda
OPENRC=${ENVF:-/etc/disk2glance/openrc}
PROPS=${PROPS:-/etc/disk2glance/props.json}
COW_MB=
CONFIG=/etc/disk2glance/disk2glance.conf
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do [ "${ARGS[$i]}" = --config ] && CONFIG=${ARGS[$((i+1))]:-}; done
if [ -f "$CONFIG" ]; then
  # only KEY=value lines for known keys are taken; the file is not executed
  while IFS='=' read -r k v; do
    v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
    case $k in
      OPENRC) OPENRC=$v ;; PROPS) PROPS=$v ;; DISK) DISK=$v ;; COW_MB) COW_MB=$v ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$CONFIG")
else
  for a in ${ARGS[@]+"${ARGS[@]}"}; do
    [ "$a" = --config ] && { echo "config file $CONFIG not found" >&2; exit 64; }
  done
fi
NAME=
CHECK=0
KEEP_MODULE=0
DETACH=0
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --openrc) OPENRC=$2; shift ;;
    --props) PROPS=$2; shift ;;
    --config) shift ;;
    --disk) DISK=$2; shift ;;
    --name) NAME=$2; shift ;;
    --keep-module) KEEP_MODULE=1 ;;
    --cow-mb) COW_MB=$2; shift ;;
    --detach) DETACH=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 64 ;;
    *) NAME=$1 ;;
  esac
  shift
done
NAME=${NAME:-$(hostname -s)-$(date -u +%Y%m%d-%H%M%S)}
WORK=/run/disk2glance
COW=.datto_d2g
log() { echo "$(date -u +%T) $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

# --detach: re-run ourselves outside the login session. Some systems (Astra Linux) have
# logind KillUserProcesses=yes, which SIGTERMs everything in the session on logout — nohup
# does not help there; a transient system unit does.
if [ "$DETACH" = 1 ]; then
  command -v systemd-run >/dev/null || die "--detach needs systemd-run"
  unit=disk2glance-$(date +%Y%m%d-%H%M%S)
  rest=(); for a in "${ARGS[@]}"; do [ "$a" = --detach ] || rest+=("$a"); done
  systemd-run --unit="$unit" --description="disk2glance $NAME" \
    /bin/bash -c 'exec "$0" "$@" >>/var/log/disk2glance.log 2>&1' "$(readlink -f "$0")" ${rest[@]+"${rest[@]}"} --name "$NAME" >/dev/null \
    || die "systemd-run failed"
  log "started as systemd unit $unit; follow: tail -f /var/log/disk2glance.log   status: systemctl status $unit"
  exit 0
fi
mkdir -p "$WORK"; chmod 700 "$WORK"
exec 9>"$WORK/lock"; flock -n 9 || die "another disk2glance is running"
echo $$ > "$WORK/pid"
log "disk2glance $VERSION, kernel $(uname -r), disk $DISK"

# --- dattobd module ------------------------------------------------------------
LOADED_BY_US=0
load_module() {
  [ -e /proc/datto-info ] && return 0
  local ko="$PREFIX/modules/$(uname -r)/dattobd.ko"
  if [ -f "$ko" ]; then
    insmod "$ko" || die "insmod $ko failed: check dmesg; causes: Secure Boot / lockdown / Astra ZPS, or SELinux label (ls -Z $ko must show modules_object_t; reinstall with install.sh)"
  else
    modprobe dattobd 2>/dev/null || die "no dattobd module for kernel $(uname -r) — see docs/build-modules.md"
  fi
  LOADED_BY_US=1
}

# --- config files ------------------------------------------------------------------
[ -f "$OPENRC" ] || die "credentials file $OPENRC not found — create it (docs/quickstart.md, step 4) or pass --openrc FILE"
# openrc files downloaded from cloud portals often ask for the password interactively
# ('read -s OS_PASSWORD_INPUT'); the agent runs unattended, so the password must be in the file
if grep -qE '^[[:space:]]*read[[:space:]]' "$OPENRC"; then
  die "$OPENRC asks for input ('read ...'): put the password into it as: export OS_PASSWORD='...' and remove the read/prompt lines"
fi
if grep -qE '^[^#]*="<' "$OPENRC"; then
  die "$OPENRC is still a template: replace the <...> values (docs/quickstart.md, step 4)"
fi
perm=$(stat -c %a "$OPENRC"); case $perm in 600|400) ;; *) log "WARN: $OPENRC has mode $perm — run: chmod 600 $OPENRC" ;; esac
# shellcheck disable=SC1090
. "$OPENRC"
missing=
for v in OS_AUTH_URL; do [ -n "${!v:-}" ] || missing="$missing $v"; done
if [ -z "${OS_APPLICATION_CREDENTIAL_ID:-}" ]; then
  for v in OS_USERNAME OS_PASSWORD OS_PROJECT_ID; do [ -n "${!v:-}" ] || missing="$missing $v"; done
fi
[ -z "$missing" ] || die "$OPENRC does not set:$missing"
if [ -f "$PROPS" ]; then
  jq -e 'type=="object"' "$PROPS" >/dev/null 2>&1 || die "$PROPS is not a JSON object"
  log "credentials: $OPENRC; image properties: $PROPS ($(jq -r 'keys|join(",")' "$PROPS"))"
else
  log "credentials: $OPENRC; WARN: no image properties file $PROPS — the image gets no os_*/hw_* properties"
fi

# --- auth: token + Glance endpoint from the catalog ------------------------------
if [ -n "${OS_APPLICATION_CREDENTIAL_ID:-}" ]; then
  auth_body=$(jq -n --arg id "$OS_APPLICATION_CREDENTIAL_ID" --arg s "$OS_APPLICATION_CREDENTIAL_SECRET" \
    '{auth:{identity:{methods:["application_credential"],application_credential:{id:$id,secret:$s}}}}')
else
  auth_body=$(jq -n --arg u "$OS_USERNAME" --arg d "${OS_USER_DOMAIN_NAME:-Default}" \
    --arg p "$OS_PASSWORD" --arg pid "$OS_PROJECT_ID" \
    '{auth:{identity:{methods:["password"],password:{user:{name:$u,domain:{name:$d},password:$p}}},scope:{project:{id:$pid}}}}')
fi
curl -sS --fail -D "$WORK/auth.hdr" -o "$WORK/auth.json" -H 'Content-Type: application/json' \
  -d "$auth_body" "${OS_AUTH_URL%/}/auth/tokens" || die "Keystone auth failed"
unset auth_body
TOKEN=$(awk 'tolower($1)=="x-subject-token:"{print $2}' "$WORK/auth.hdr" | tr -d '\r')
GLANCE=${GLANCE:-$(jq -r --arg r "${OS_REGION_NAME:-RegionOne}" \
  '.token.catalog[]|select(.type=="image").endpoints[]|select(.interface=="public" and .region_id==$r).url' "$WORK/auth.json")}
rm -f "$WORK/auth.hdr" "$WORK/auth.json"
[ -n "$TOKEN" ] && [ -n "$GLANCE" ] || die "no token or Glance endpoint"
log "auth OK, Glance $GLANCE"

# --- layout from sysfs (works without sfdisk --json, e.g. CentOS 7) ---------------
dev=$(basename "$(readlink -f "$DISK")")
[ -d "/sys/class/block/$dev" ] || die "$DISK is not a block device"
DISK_BYTES=$(( $(cat /sys/class/block/$dev/size) * 512 ))
PARTS=()   # "start_bytes size_bytes node", sorted by start
while read -r start size node; do PARTS+=("$start $size $node"); done < <(
  for p in /sys/class/block/$dev/${dev}*; do
    [ -f "$p/partition" ] || continue
    echo "$(( $(cat "$p/start") * 512 )) $(( $(cat "$p/size") * 512 )) /dev/$(basename "$p")"
  done | sort -n)
[ ${#PARTS[@]} -gt 0 ] || die "no partitions on $DISK (whole-disk filesystems are not supported yet)"

# --- plan: which block devices to snapshot and where their bytes live on the disk ---
# TARGETS: "dev mnt" to snapshot (a partition, or an LVM logical volume)
# MAPS:    "dev dev_off len disk_off" — byte ranges of a target as they sit on $DISK
TARGETS=()
MAPS=()
declare -A PART_START   # "maj:min" of each partition -> start byte on $DISK
for p in "${PARTS[@]}"; do
  read -r start size node <<<"$p"
  PART_START[$(cat /sys/class/block/$(basename "$node")/dev)]=$start
done

fs_of() { # dev -> "mnt fstype" (empty if not mounted)
  findmnt -rn -S "$1" -o TARGET,FSTYPE | head -1
}
plan_fs() { # dev fstype mnt label -> 0 if it must be snapshotted
  case "${2:-}" in
    ext4|ext3|xfs) return 0 ;;
    btrfs) die "$4 is btrfs (mounted at $3) — not supported (dattobd has no btrfs support)" ;;
    *) return 1 ;;
  esac
}

declare -A SEEN_DM
for p in "${PARTS[@]}"; do
  read -r start size node <<<"$p"
  pname=$(basename "$node")
  holders=$(ls /sys/class/block/$pname/holders 2>/dev/null | tr '\n' ' ')
  if [ -z "${holders// }" ]; then
    mnt=; fstype=
    read -r mnt fstype < <(fs_of "$node") || true
    if plan_fs "$node" "${fstype:-}" "${mnt:-}" "$node"; then
      TARGETS+=("$node $mnt"); MAPS+=("$node 0 $size $start"); how=snap
    else how=raw; fi
    log "  $node start=$start size=$size fs=${fstype:-none} mnt=${mnt:--} -> $how"
    continue
  fi
  # partition is used by device-mapper: only LVM linear volumes on this disk are supported
  log "  $node start=$start size=$size -> container for: $holders"
  for h in $holders; do
    [ -n "${SEEN_DM[$h]:-}" ] && continue; SEEN_DM[$h]=1
    uuid=$(cat /sys/class/block/$h/dm/uuid 2>/dev/null || true)
    name=$(cat /sys/class/block/$h/dm/name 2>/dev/null || echo "$h")
    case $uuid in
      LVM-*) ;;
      CRYPT-*) die "$node holds dm-crypt device $name — encrypted volumes are not supported" ;;
      *) die "$node is used by $h ($name, ${uuid%%-*}) — only LVM is supported (no mdraid/multipath)" ;;
    esac
    [ -z "$(ls -A /sys/class/block/$h/holders 2>/dev/null)" ] || die "LV $name is itself used by $(ls /sys/class/block/$h/holders | tr '\n' ' ')— nested device-mapper not supported"
    command -v dmsetup >/dev/null || die "dmsetup not found (device-mapper package)"
    lvdev=/dev/mapper/$name
    mnt=; fstype=
    read -r mnt fstype < <(fs_of "$lvdev") || true
    if plan_fs "$lvdev" "${fstype:-}" "${mnt:-}" "LV $name"; then
      while read -r s l target dmaj off rest; do
        [ "$target" = linear ] || die "LV $name has a '$target' segment — only linear LVs are supported (no thin/raid/striped/snapshot)"
        ps=${PART_START[$dmaj]:-}
        [ -n "$ps" ] || die "LV $name has extents on $dmaj, which is not a partition of $DISK (VG spans disks)"
        MAPS+=("$lvdev $((s*512)) $((l*512)) $((ps + off*512))")
      done < <(dmsetup table "$name")
      TARGETS+=("$lvdev $mnt"); how=snap
    else
      # not snapshotted (swap, unmounted): its bytes are read from the disk as they are
      dmsetup table "$name" | awk '$3!="linear"{bad=1} END{exit bad}' \
        || log "    note: LV $name is not linear; read raw, unmounted/swap so content is not critical"
      how=raw
    fi
    log "    LV $name fs=${fstype:-none} mnt=${mnt:--} segments=$(dmsetup table "$name" | wc -l) -> $how"
  done
done
[ ${#TARGETS[@]} -gt 0 ] || log "WARN: nothing to snapshot — the disk will be read as is (inconsistent if mounted rw)"

load_module
log "dattobd $(jq -r .version /proc/datto-info) loaded"

# --- guest readiness for KVM (VK Cloud and other OpenStack clouds) -----------------
# The agent copies the disk as is and changes nothing in the guest. These checks only
# warn about what would stop the new VM from booting or reaching the network.
guest_checks() {
  local kv virt cfg rd lister mods m warn=0
  kv=$(uname -r)
  virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  log "guest: hypervisor now: $virt (target: KVM, virtio devices)"
  cfg=/boot/config-$kv
  if [ -f "$cfg" ]; then
    for m in VIRTIO_PCI VIRTIO_BLK VIRTIO_NET; do
      case $(grep -E "^CONFIG_$m=" "$cfg" | cut -d= -f2) in
        y) ;;
        m) mods="${mods:-} $(echo $m | tr 'A-Z' 'a-z')" ;;
        *) log "  WARN: kernel has no CONFIG_$m — the new VM will not see its disk/network"; warn=1 ;;
      esac
    done
  fi
  # disk drivers built as modules must be in the initramfs, or the root fs is not found at boot
  rd=; for f in /boot/initramfs-$kv.img /boot/initrd.img-$kv /boot/initrd-$kv; do [ -f "$f" ] && rd=$f && break; done
  if command -v lsinitrd >/dev/null; then lister="lsinitrd"; elif command -v lsinitramfs >/dev/null; then lister="lsinitramfs"; fi
  # listing goes to a file: 'lister | grep -q' under pipefail reads grep's early exit as failure
  rm -f "$WORK/initrd.list"
  if [ -n "$rd" ] && [ -n "${lister:-}" ]; then $lister "$rd" >"$WORK/initrd.list" 2>/dev/null || true; fi
  for m in ${mods:-}; do
    [ "$m" = virtio_net ] && continue          # network driver is loaded after boot, from /lib/modules
    if [ -s "$WORK/initrd.list" ]; then
      grep -q "/$m\.ko" "$WORK/initrd.list" \
        || { log "  WARN: $m is a module but missing from $rd — add it before migrating (docs/guest-drivers.md)"; warn=1; }
    else
      log "  note: cannot inspect initramfs for $m (no lsinitrd/lsinitramfs)"
    fi
  done
  # disk names change to /dev/vdX on KVM: fstab must not use /dev/sdX, /dev/xvdX, /dev/hdX
  if grep -E '^[[:space:]]*/dev/(sd|xvd|hd)[a-z]' /etc/fstab >/dev/null 2>&1; then
    log "  WARN: /etc/fstab uses /dev/sdX-style names; on KVM disks become /dev/vdX — use UUID= or LABEL="; warn=1
  fi
  command -v cloud-init >/dev/null \
    || { log "  WARN: cloud-init not installed: network config bound to the old interface name/MAC may not come up on the new VM"; warn=1; }
  if [ -f "$PROPS" ] && [ "$(jq -r '.hw_qemu_guest_agent // empty' "$PROPS")" = yes ] && ! command -v qemu-ga >/dev/null; then
    log "  WARN: props.json sets hw_qemu_guest_agent=yes but qemu-guest-agent is not installed"; warn=1
  fi
  GUEST_WARN=$warn
  [ "$warn" = 0 ] && log "guest: OK for KVM (virtio drivers available at boot, fstab by UUID/LABEL)"
  return 0
}

# --- permission check: can this account create images? ------------------------------
perm_check() {
  local id
  id=$(curl -sS --fail -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name":"disk2glance-permission-check","disk_format":"raw","container_format":"bare","visibility":"private"}' \
    "${GLANCE%/}/v2/images" | jq -r .id) || die "this account cannot create images in Glance (see docs/service-accounts.md)"
  curl -sS --fail -X DELETE -H "X-Auth-Token: $TOKEN" "${GLANCE%/}/v2/images/$id" >/dev/null \
    || log "WARN: test image $id could not be deleted — remove it by hand"
  log "permissions: image create/delete in Glance OK"
}

if [ "$CHECK" = 1 ]; then
  guest_checks
  perm_check
  if [ "$LOADED_BY_US" = 1 ] && [ "$KEEP_MODULE" = 0 ]; then rmmod dattobd; fi
  if [ "${GUEST_WARN:-0}" = 1 ]; then
    log "CHECK OK, BUT see the guest WARN lines above: fix them before migrating or the new VM may not boot (docs/guest-drivers.md)"
  else
    log "CHECK OK: image would be $DISK_BYTES bytes raw"
  fi
  exit 0
fi
guest_checks

# --- snapshots -------------------------------------------------------------------
declare -A SNAPDEV
MINORS=()
UPID=
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill -TERM "$1" 2>/dev/null || true; }
cleanup() {
  local m i
  # stop the upload pipeline first: a dd still reading /dev/dattoN makes destroy fail with EBUSY
  if [ -n "$UPID" ]; then killtree "$UPID"; wait "$UPID" 2>/dev/null || true; UPID=; fi
  for m in ${MINORS[@]+"${MINORS[@]}"}; do
    for i in 1 2 3 4 5; do dbdctl destroy "$m" >/dev/null 2>&1 && break; sleep 2; done
    [ -e "/dev/datto$m" ] && log "WARN: destroy minor $m failed — run: dbdctl destroy $m"
  done
  MINORS=()
  fb_remove
  if [ "$LOADED_BY_US" = 1 ] && [ "$KEEP_MODULE" = 0 ] && [ -e /proc/datto-info ]; then
    rmmod dattobd 2>/dev/null && LOADED_BY_US=0 || log "WARN: rmmod dattobd failed"
  fi
}
# --- COW files on the new VM ---------------------------------------------------------------
# dattobd creates its COW file on the snapshotted filesystem just before the snapshot, so the
# file (10% of the filesystem by default) is part of the copy. A one-shot unit written before
# the snapshot and removed from the source right after it deletes these files on the first
# boot of the new VM, then deletes itself. The source keeps no trace of it.
FB_UNIT=/etc/systemd/system/disk2glance-cowclean.service
FB_LINK=/etc/systemd/system/multi-user.target.wants/disk2glance-cowclean.service
fb_install() {
  local files= t tdev tmnt
  [ ${#TARGETS[@]} -gt 0 ] || return 0
  if [ ! -d /etc/systemd/system ]; then log "WARN: no systemd: delete the $COW files on the new VM by hand"; return 0; fi
  for t in "${TARGETS[@]}"; do read -r tdev tmnt <<<"$t"; files="$files ${tmnt%/}/$COW"; done
  cat >"$FB_UNIT" <<UNIT
[Unit]
Description=disk2glance: delete dattobd COW files copied with the disk
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in$files; do [ -e "\$\$f" ] && { chattr -i "\$\$f" 2>/dev/null; rm -f "\$\$f"; }; done; rm -f $FB_LINK $FB_UNIT'
[Install]
WantedBy=multi-user.target
UNIT
  mkdir -p "${FB_LINK%/*}"; ln -sf "$FB_UNIT" "$FB_LINK"
}
fb_remove() { rm -f "$FB_LINK" "$FB_UNIT"; }

trap cleanup EXIT
trap 'log "signal received, cleaning up"; exit 130' INT TERM HUP

next_minor() { local m=0; while [ -e "/dev/datto$m" ]; do m=$((m+1)); done; echo $m; }

# Flush dirty data first: dattobd freezes the filesystem while it sets up the snapshot,
# and on a busy disk the freeze-time flush is what stalls application writes (measured:
# 17-26 s without, ~11 s with sync, ~6 s with sync + 256 MiB COW on a loaded ceph-hdd).
fb_install
t0=$(date +%s); sync; log "sync before snapshots: $(( $(date +%s) - t0 )) s"
COWOPT=(); [ -n "$COW_MB" ] && COWOPT=(-f "$COW_MB")
T_SNAP=$(date -u +%FT%T.%3NZ)
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
  read -r tdev tmnt <<<"$t"
  m=$(next_minor)
  t0=$(date +%s%N)
  dbdctl setup-snapshot ${COWOPT[@]+"${COWOPT[@]}"} "$tdev" "${tmnt%/}/$COW" "$m" || die "setup-snapshot $tdev failed"
  MINORS+=("$m"); SNAPDEV[$tdev]=/dev/datto$m
  log "snapshot $tdev ($tmnt) -> /dev/datto$m in $(( ($(date +%s%N) - t0) / 1000000 )) ms"
done
fb_remove   # the copy has the unit, the source no longer does
T_READY=$(date -u +%FT%T.%3NZ)

# --- raw disk stream -------------------------------------------------------------
# OVL: "disk_off len src src_off" sorted by disk_off; everything else comes from $DISK
OVL=()
while read -r doff len src soff; do OVL+=("$doff $len $src $soff"); done < <(
  for m in ${MAPS[@]+"${MAPS[@]}"}; do
    read -r tdev toff tlen doff <<<"$m"
    echo "$doff $tlen ${SNAPDEV[$tdev]} $toff"
  done | sort -n)
emit() { # src offset length
  [ "$3" -gt 0 ] || return 0
  dd if="$1" bs=4M iflag=skip_bytes,count_bytes,fullblock skip="$2" count="$3" status=none
}
stream() {
  local pos=0 doff len src soff
  for o in ${OVL[@]+"${OVL[@]}"}; do
    read -r doff len src soff <<<"$o"
    [ "$doff" -ge "$pos" ] || { log "overlapping ranges at $doff"; return 1; }
    emit "$DISK" "$pos" $((doff - pos))     # partition table, raw partitions, LVM metadata, gaps
    emit "$src" "$soff" "$len"              # snapshotted bytes
    pos=$((doff + len))
  done
  emit "$DISK" "$pos" $((DISK_BYTES - pos)) # rest incl. GPT backup
}
progress() { # pv if present, else plain pass-through
  if command -v pv >/dev/null; then pv -f -i 15 -s "$DISK_BYTES" -F '%t %r %a %p' 2>"$WORK/progress.log"
  else cat; fi
}

# --- create image + upload -------------------------------------------------------
props='{}'; [ -f "$PROPS" ] && props=$(jq -c . "$PROPS")
body=$(jq -n --arg n "$NAME" --arg ts "$T_SNAP" --arg h "$(hostname -s)" --arg v "$VERSION" --argjson p "$props" \
  '$p + {name:$n, disk_format:"raw", container_format:"bare", visibility:"private",
         d2g_source_host:$h, d2g_snapshot_time:$ts, d2g_version:$v}')
IMG=$(curl -sS --fail -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d "$body" "${GLANCE%/}/v2/images" | jq -r .id) || die "image create failed"
log "image $IMG ($NAME), $DISK_BYTES bytes, snapshot $T_SNAP..$T_READY"

T0=$(date +%s)
# run the pipeline in the background and wait for it, so signal traps fire immediately
( stream | progress \
  | tee >(md5sum | cut -d' ' -f1 >"$WORK/md5") >(sha512sum | cut -d' ' -f1 >"$WORK/sha512") \
  | curl -sS --fail -X PUT -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/octet-stream' \
      -T - "${GLANCE%/}/v2/images/$IMG/file" ) &
UPID=$!
wait "$UPID" || { UPID=; die "upload failed (image $IMG left in Glance)"; }
UPID=
T1=$(date +%s)
sleep 3   # let the hash process substitutions finish

cleanup

meta=$(curl -sS --fail -H "X-Auth-Token: $TOKEN" "${GLANCE%/}/v2/images/$IMG")
status=$(jq -r .status <<<"$meta"); size=$(jq -r .size <<<"$meta")
# Glance with multihash fills os_hash_value (sha512); VK Glance only fills md5 "checksum"
ghash=$(jq -r '.os_hash_value // empty' <<<"$meta"); lhash=$(cat "$WORK/sha512"); algo=sha512
[ -n "$ghash" ] || { ghash=$(jq -r .checksum <<<"$meta"); lhash=$(cat "$WORK/md5"); algo=md5; }
dt=$((T1-T0)); [ $dt -gt 0 ] || dt=1
log "upload done in $dt s ($(( DISK_BYTES / 1048576 / dt )) MiB/s): status=$status size=$size"
if [ "$status" = active ] && [ "$size" = "$DISK_BYTES" ] && [ "$ghash" = "$lhash" ]; then
  log "OK: size and $algo match Glance"
else
  die "MISMATCH: status=$status size=$size local $algo=$lhash glance=$ghash"
fi
echo "$IMG"
