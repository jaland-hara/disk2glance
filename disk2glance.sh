#!/bin/bash
# disk2glance — stream a live disk into a Glance image (raw), no temp files.
#
# Mounted ext4/xfs partitions are read from dattobd snapshots (crash-consistent,
# all taken back to back); everything else (partition table, BIOS boot, EFI,
# gaps, GPT backup) is read straight from the disk.
#
# Usage: disk2glance.sh [image-name]
# Env:   DISK=/dev/vda  ENVF=/etc/disk2glance/openrc  PROPS=/etc/disk2glance/props.json
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:$PATH   # sudo secure_path on RHEL-likes drops /usr/local

DISK=${DISK:-/dev/vda}
ENVF=${ENVF:-/etc/disk2glance/openrc}
PROPS=${PROPS:-/etc/disk2glance/props.json}
NAME=${1:-$(hostname -s)-$(date -u +%Y%m%d-%H%M%S)}
WORK=/run/disk2glance
COW=.datto_d2g
mkdir -p "$WORK"
log() { echo "$(date -u +%T) $*" >&2; }

# shellcheck disable=SC1090
. "$ENVF"

# --- auth: token + Glance endpoint from the catalog -------------------------
auth_body=$(jq -n --arg u "$OS_USERNAME" --arg d "$OS_USER_DOMAIN_NAME" \
  --arg p "$OS_PASSWORD" --arg pid "$OS_PROJECT_ID" \
  '{auth:{identity:{methods:["password"],password:{user:{name:$u,domain:{name:$d},password:$p}}},scope:{project:{id:$pid}}}}')
curl -sS --fail -D "$WORK/auth.hdr" -o "$WORK/auth.json" -H 'Content-Type: application/json' \
  -d "$auth_body" "${OS_AUTH_URL%/}/auth/tokens"
TOKEN=$(awk 'tolower($1)=="x-subject-token:"{print $2}' "$WORK/auth.hdr" | tr -d '\r')
GLANCE=${GLANCE:-$(jq -r --arg r "${OS_REGION_NAME:-RegionOne}" \
  '.token.catalog[]|select(.type=="image").endpoints[]|select(.interface=="public" and .region_id==$r).url' "$WORK/auth.json")}
rm -f "$WORK/auth.hdr" "$WORK/auth.json"
[ -n "$TOKEN" ] && [ -n "$GLANCE" ] || { log "auth failed"; exit 1; }

# --- layout ------------------------------------------------------------------
SS=$(sfdisk --json "$DISK" | jq -r '.partitiontable.sectorsize // 512')
DISK_BYTES=$(blockdev --getsize64 "$DISK")
# "start size node" sorted by start, in bytes
mapfile -t PARTS < <(sfdisk --json "$DISK" | jq -r --argjson ss "$SS" \
  '.partitiontable.partitions|sort_by(.start)[]|"\(.start*$ss) \(.size*$ss) \(.node)"')

# --- snapshots ---------------------------------------------------------------
declare -A SNAPDEV
MINORS=()
cleanup() {
  for m in "${MINORS[@]}"; do dbdctl destroy "$m" >/dev/null 2>&1 || log "WARN: destroy minor $m failed"; done
}
trap cleanup EXIT

next_minor() {
  local m=0
  while [ -e "/dev/datto$m" ]; do m=$((m+1)); done
  echo $m
}

T_SNAP=$(date -u +%FT%T.%3NZ)
for p in "${PARTS[@]}"; do
  read -r _ _ node <<<"$p"
  mnt=; fstype=
  read -r mnt fstype < <(findmnt -rn -S "$node" -o TARGET,FSTYPE | head -1) || true
  case "${fstype:-}" in
    ext4|ext3|xfs)
      m=$(next_minor)
      dbdctl setup-snapshot "$node" "${mnt%/}/$COW" "$m"
      MINORS+=("$m"); SNAPDEV[$node]=/dev/datto$m
      log "snapshot $node ($mnt) -> /dev/datto$m"
      ;;
    *) log "raw read $node (${fstype:-unmounted})" ;;
  esac
done
T_READY=$(date -u +%FT%T.%3NZ)

# --- raw disk stream ---------------------------------------------------------
emit() { # src offset length
  [ "$3" -gt 0 ] || return 0
  dd if="$1" bs=4M iflag=skip_bytes,count_bytes,fullblock skip="$2" count="$3" status=none
}
stream() {
  local pos=0 start size node
  for p in "${PARTS[@]}"; do
    read -r start size node <<<"$p"
    emit "$DISK" "$pos" $((start - pos))                     # gap / table / GPT header
    if [ -n "${SNAPDEV[$node]:-}" ]; then emit "${SNAPDEV[$node]}" 0 "$size"
    else emit "$DISK" "$start" "$size"; fi
    pos=$((start + size))
  done
  emit "$DISK" "$pos" $((DISK_BYTES - pos))                  # tail incl. GPT backup
}

# --- create image + upload -----------------------------------------------------
props='{}'; [ -f "$PROPS" ] && props=$(cat "$PROPS")
body=$(jq -n --arg n "$NAME" --arg ts "$T_SNAP" --arg h "$(hostname -s)" --argjson p "$props" \
  '$p + {name:$n, disk_format:"raw", container_format:"bare", visibility:"private",
         d2g_source_host:$h, d2g_snapshot_time:$ts}')
IMG=$(curl -sS --fail -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d "$body" "${GLANCE%/}/v2/images" | jq -r .id)
log "image $IMG ($NAME), disk $DISK_BYTES bytes, snapshot $T_SNAP..$T_READY"

T0=$(date +%s)
stream | pv -f -i 15 -s "$DISK_BYTES" -F '%t %r %a %p' 2>"$WORK/pv.log" \
  | tee >(md5sum | cut -d' ' -f1 >"$WORK/md5") >(sha512sum | cut -d' ' -f1 >"$WORK/sha512") \
  | curl -sS --fail -X PUT -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/octet-stream' \
      -T - "${GLANCE%/}/v2/images/$IMG/file"
T1=$(date +%s)
sleep 3   # let the hash process substitutions finish

cleanup; MINORS=()

meta=$(curl -sS --fail -H "X-Auth-Token: $TOKEN" "${GLANCE%/}/v2/images/$IMG")
status=$(jq -r .status <<<"$meta"); size=$(jq -r .size <<<"$meta")
# Glance with multihash fills os_hash_value (sha512); VK Glance only fills md5 "checksum"
ghash=$(jq -r '.os_hash_value // empty' <<<"$meta"); lhash=$(cat "$WORK/sha512"); algo=sha512
[ -n "$ghash" ] || { ghash=$(jq -r .checksum <<<"$meta"); lhash=$(cat "$WORK/md5"); algo=md5; }
log "upload done in $((T1-T0)) s ($(( DISK_BYTES / 1048576 / (T1-T0>0 ? T1-T0 : 1) )) MiB/s): status=$status size=$size"
if [ "$status" = active ] && [ "$size" = "$DISK_BYTES" ] && [ "$ghash" = "$lhash" ]; then
  log "OK: size and $algo match Glance"
else
  log "MISMATCH: local $algo=$lhash glance=$ghash"; exit 2
fi
echo "$IMG"
