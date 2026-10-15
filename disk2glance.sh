#!/bin/bash
# disk2glance — stream a live Linux disk into an OpenStack Glance image (raw), no temp files.
#
# Mounted ext4/ext3/xfs filesystems — on partitions or on linear LVM volumes — are
# read from dattobd copy-on-write snapshots (crash-consistent, taken back to back);
# everything else (partition table, BIOS boot, EFI, swap, LVM metadata, free
# extents, gaps, GPT backup) is read straight from the disk.
#
# Usage: disk2glance [--check] [--disk /dev/vda] [--name NAME] [--cow-mb N] [--keep-module]
#   --check        preflight only: auth, Glance endpoint, layout, module load; no upload
#   --cow-mb N     COW file size per snapshot in MiB (default: dattobd's 10% of the volume);
#                  smaller = shorter write pause at snapshot time on busy disks, but overflows sooner
#   --keep-module  leave dattobd loaded afterwards (default: unload if we loaded it)
# Config: /etc/disk2glance/openrc (OS_* variables), /etc/disk2glance/props.json (image properties)
set -euo pipefail
PREFIX=${PREFIX:-/opt/disk2glance}
export PATH=$PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VERSION=$(cat "$PREFIX/VERSION" 2>/dev/null || echo dev)

DISK=${DISK:-/dev/vda}
ENVF=${ENVF:-/etc/disk2glance/openrc}
PROPS=${PROPS:-/etc/disk2glance/props.json}
NAME=
CHECK=0
KEEP_MODULE=0
COW_MB=
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --disk) DISK=$2; shift ;;
    --name) NAME=$2; shift ;;
    --keep-module) KEEP_MODULE=1 ;;
    --cow-mb) COW_MB=$2; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
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
mkdir -p "$WORK"; chmod 700 "$WORK"
exec 9>"$WORK/lock"; flock -n 9 || die "another disk2glance is running"
echo $$ > "$WORK/pid"
log "disk2glance $VERSION, kernel $(uname -r), disk $DISK"

# --- dattobd module ------------------------------------------------------------
LOADED_BY_US=0
load_module() {
  [ -e /proc/datto-info ] && return 0
  local ko="$PREFIX/modules/$(uname -r)/dattobd.ko"
  if [ -f "$ko" ]; then insmod "$ko" || die "insmod $ko failed (Secure Boot / integrity control?)"
  else modprobe dattobd 2>/dev/null || die "no dattobd module for kernel $(uname -r) — see docs/build-modules.md"
  fi
  LOADED_BY_US=1
}

# --- auth: token + Glance endpoint from the catalog ------------------------------
# shellcheck disable=SC1090
. "$ENVF"
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

if [ "$CHECK" = 1 ]; then
  if [ "$LOADED_BY_US" = 1 ] && [ "$KEEP_MODULE" = 0 ]; then rmmod dattobd; fi
  log "CHECK OK: image would be $DISK_BYTES bytes raw"
  exit 0
fi

# --- snapshots -------------------------------------------------------------------
declare -A SNAPDEV
MINORS=()
cleanup() {
  local m
  for m in ${MINORS[@]+"${MINORS[@]}"}; do dbdctl destroy "$m" >/dev/null 2>&1 || log "WARN: destroy minor $m failed"; done
  MINORS=()
  if [ "$LOADED_BY_US" = 1 ] && [ "$KEEP_MODULE" = 0 ] && [ -e /proc/datto-info ]; then
    rmmod dattobd 2>/dev/null && LOADED_BY_US=0 || log "WARN: rmmod dattobd failed"
  fi
}
trap cleanup EXIT

next_minor() { local m=0; while [ -e "/dev/datto$m" ]; do m=$((m+1)); done; echo $m; }

# Flush dirty data first: dattobd freezes the filesystem while it sets up the snapshot,
# and on a busy disk the freeze-time flush is what stalls application writes (measured:
# 17-26 s without, ~11 s with sync, ~6 s with sync + 256 MiB COW on a loaded ceph-hdd).
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
props='{}'; [ -f "$PROPS" ] && props=$(cat "$PROPS")
body=$(jq -n --arg n "$NAME" --arg ts "$T_SNAP" --arg h "$(hostname -s)" --arg v "$VERSION" --argjson p "$props" \
  '$p + {name:$n, disk_format:"raw", container_format:"bare", visibility:"private",
         d2g_source_host:$h, d2g_snapshot_time:$ts, d2g_version:$v}')
IMG=$(curl -sS --fail -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d "$body" "${GLANCE%/}/v2/images" | jq -r .id) || die "image create failed"
log "image $IMG ($NAME), $DISK_BYTES bytes, snapshot $T_SNAP..$T_READY"

T0=$(date +%s)
stream | progress \
  | tee >(md5sum | cut -d' ' -f1 >"$WORK/md5") >(sha512sum | cut -d' ' -f1 >"$WORK/sha512") \
  | curl -sS --fail -X PUT -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/octet-stream' \
      -T - "${GLANCE%/}/v2/images/$IMG/file" || die "upload failed (image $IMG left in Glance)"
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
