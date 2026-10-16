#!/bin/bash
# disk2s3 (experimental) — upload a live Linux disk into one S3 object (raw image) with a
# parallel multipart upload. Same snapshot logic as disk2glance: mounted ext3/ext4/xfs on
# partitions or linear LVM volumes are read from dattobd snapshots, everything else raw.
#
# Every part is an independent byte range of the composed disk: it is read into RAM
# (/dev/shm), MD5-checked by S3 (Content-MD5) and retried on failure while the snapshot
# stays alive. No AWS CLI needed: requests are signed with SigV4 via openssl.
#
# Usage: disk2s3 [--check] [--name NAME] [--s3env FILE] [--disk /dev/vda] [--prefix P]
#                [--part-mb 128] [--threads 8] [--cow-mb N] [--keep-module]
#   --s3env FILE  S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY, S3_SECRET_KEY
#                 default: /etc/disk2glance/s3.env
#   --prefix P    object key prefix; the image goes to <P><NAME>/disk.raw  default: d2g/
#   --part-mb N   part size in MiB (S3: at most 10000 parts)              default: 128
#   --threads N   parts uploaded in parallel                               default: 8
set -euo pipefail
PREFIX=${PREFIX:-/opt/disk2glance}
export PATH=$PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VERSION=$(cat "$PREFIX/VERSION" 2>/dev/null || echo dev)

DISK=/dev/vda
S3ENV=/etc/disk2glance/s3.env
KEYPREFIX=d2g/
PART_MB=128
THREADS=8
COW_MB=
NAME=
CHECK=0
KEEP_MODULE=0
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --s3env) S3ENV=$2; shift ;;
    --disk) DISK=$2; shift ;;
    --name) NAME=$2; shift ;;
    --prefix) KEYPREFIX=$2; shift ;;
    --part-mb) PART_MB=$2; shift ;;
    --threads) THREADS=$2; shift ;;
    --cow-mb) COW_MB=$2; shift ;;
    --keep-module) KEEP_MODULE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
NAME=${NAME:-$(hostname -s)-$(date -u +%Y%m%d-%H%M%S)}
WORK=/run/disk2s3
COW=.datto_d2g
log() { echo "$(date -u +%T) $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
mkdir -p "$WORK"; chmod 700 "$WORK"
exec 9>"$WORK/lock"; flock -n 9 || die "another disk2s3 is running"
log "disk2s3 $VERSION, kernel $(uname -r), disk $DISK, part ${PART_MB} MiB x $THREADS threads"

# --- S3 ------------------------------------------------------------------------------
[ -f "$S3ENV" ] || die "S3 settings file $S3ENV not found"
# shellcheck disable=SC1090
. "$S3ENV"
for v in S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY; do [ -n "${!v:-}" ] || die "$S3ENV does not set $v"; done
S3_REGION=${S3_REGION:-ru-msk}
S3_ENDPOINT=${S3_ENDPOINT%/}
S3_HOST=${S3_ENDPOINT#*://}; S3_HOST=${S3_HOST%%/*}
export S3_ENDPOINT S3_BUCKET S3_REGION S3_ACCESS_KEY S3_SECRET_KEY S3_HOST

hmac_hex() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | awk '{print $NF}'; }
enc_path() { # URI-encode a key, keeping '/'
  local s=$1 o= c i
  for ((i=0; i<${#s}; i++)); do c=${s:i:1}
    case $c in [A-Za-z0-9._~/-]) o+=$c ;; *) o+=$(printf '%%%02X' "'$c") ;; esac
  done
  printf '%s' "$o"
}
enc_val() { local o; o=$(enc_path "$1"); printf '%s' "${o//\//%2F}"; }   # query values: '/' encoded too
# s3req METHOD KEY QUERY OUTFILE [curl args...] -> prints the HTTP status code
# QUERY must be canonical (sorted, URI-encoded). Payload is not hashed (UNSIGNED-PAYLOAD,
# HTTPS only); part integrity is checked by S3 through Content-MD5.
s3req() {
  local method=$1 key=$2 query=$3 out=$4; shift 4
  local amzdate day path creq scope sts k sig
  amzdate=$(date -u +%Y%m%dT%H%M%SZ); day=${amzdate%%T*}
  path="/$S3_BUCKET/$(enc_path "$key")"
  creq=$(printf '%s\n' "$method" "$path" "$query" "host:$S3_HOST" "x-amz-content-sha256:UNSIGNED-PAYLOAD" \
    "x-amz-date:$amzdate" "" "host;x-amz-content-sha256;x-amz-date"; printf 'UNSIGNED-PAYLOAD')
  scope="$day/$S3_REGION/s3/aws4_request"
  sts=$(printf '%s\n' AWS4-HMAC-SHA256 "$amzdate" "$scope"; printf '%s' "$creq" | sha256sum | cut -d' ' -f1)
  k=$(printf '%s' "AWS4$S3_SECRET_KEY" | od -An -tx1 | tr -d ' \n')
  for p in "$day" "$S3_REGION" s3 aws4_request; do k=$(hmac_hex "$k" "$p"); done
  sig=$(hmac_hex "$k" "$sts")
  local code rc
  code=$(curl -sS --connect-timeout 30 -o "$out" -w '%{http_code}' -X "$method" \
    -H "x-amz-date: $amzdate" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
    -H "Authorization: AWS4-HMAC-SHA256 Credential=$S3_ACCESS_KEY/$scope, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=$sig" \
    "$@" "$S3_ENDPOINT$path${query:+?$query}"); rc=$?
  # on a transport error curl may already have printed 100 (Continue): report "000/curl<rc>"
  if [ $rc = 0 ]; then printf '%s' "$code"; else printf '000/curl%s' "$rc"; fi
}
export -f hmac_hex enc_path enc_val s3req
# control requests (create, complete, head, manifest) are retried too: VK S3 sometimes hangs
# for minutes on the TLS handshake. Usage: s3retry WANT_CODE s3req-args... -> last code
s3retry() {
  local want=$1 code try; shift
  for try in $(seq 1 8); do
    code=$(s3req "$@")
    [ "$code" = "$want" ] && { printf '%s' "$code"; return 0; }
    log "  S3 $1 ${2##*/}: HTTP $code (try $try), retrying"
    sleep $(( try * 5 < 60 ? try * 5 : 60 ))
  done
  printf '%s' "$code"
}

code=$(s3req GET "" "list-type=2&max-keys=1&prefix=$(enc_val "$KEYPREFIX")" "$WORK/s3check.xml")
[ "$code" = 200 ] || die "S3 bucket $S3_BUCKET not accessible: HTTP $code $(head -c 300 "$WORK/s3check.xml")"
log "S3 OK: $S3_ENDPOINT bucket $S3_BUCKET"

# --- layout from sysfs (same as disk2glance) -----------------------------------------
dev=$(basename "$(readlink -f "$DISK")")
[ -d "/sys/class/block/$dev" ] || die "$DISK is not a block device"
DISK_BYTES=$(( $(cat /sys/class/block/$dev/size) * 512 ))
PARTS=()
while read -r start size node; do PARTS+=("$start $size $node"); done < <(
  for p in /sys/class/block/$dev/${dev}*; do
    [ -f "$p/partition" ] || continue
    echo "$(( $(cat "$p/start") * 512 )) $(( $(cat "$p/size") * 512 )) /dev/$(basename "$p")"
  done | sort -n)
[ ${#PARTS[@]} -gt 0 ] || die "no partitions on $DISK"
TARGETS=(); MAPS=()
declare -A PART_START
for p in "${PARTS[@]}"; do read -r start size node <<<"$p"; PART_START[$(cat /sys/class/block/$(basename "$node")/dev)]=$start; done
fs_of() { findmnt -rn -S "$1" -o TARGET,FSTYPE | head -1; }
plan_fs() { case "${2:-}" in ext4|ext3|xfs) return 0 ;; btrfs) die "$4 is btrfs — not supported" ;; *) return 1 ;; esac; }
declare -A SEEN_DM
for p in "${PARTS[@]}"; do
  read -r start size node <<<"$p"
  pname=$(basename "$node")
  holders=$(ls /sys/class/block/$pname/holders 2>/dev/null | tr '\n' ' ')
  if [ -z "${holders// }" ]; then
    mnt=; fstype=
    read -r mnt fstype < <(fs_of "$node") || true
    if plan_fs "$node" "${fstype:-}" "${mnt:-}" "$node"; then TARGETS+=("$node $mnt"); MAPS+=("$node 0 $size $start"); how=snap; else how=raw; fi
    log "  $node start=$start size=$size fs=${fstype:-none} mnt=${mnt:--} -> $how"
    continue
  fi
  for h in $holders; do
    [ -n "${SEEN_DM[$h]:-}" ] && continue; SEEN_DM[$h]=1
    uuid=$(cat /sys/class/block/$h/dm/uuid 2>/dev/null || true); name=$(cat /sys/class/block/$h/dm/name 2>/dev/null || echo "$h")
    case $uuid in LVM-*) ;; *) die "$node is used by $h ($name) — only linear LVM is supported" ;; esac
    lvdev=/dev/mapper/$name; mnt=; fstype=
    read -r mnt fstype < <(fs_of "$lvdev") || true
    if plan_fs "$lvdev" "${fstype:-}" "${mnt:-}" "LV $name"; then
      while read -r s l target dmaj off rest; do
        [ "$target" = linear ] || die "LV $name has a '$target' segment"
        ps=${PART_START[$dmaj]:-}; [ -n "$ps" ] || die "LV $name spans disks"
        MAPS+=("$lvdev $((s*512)) $((l*512)) $((ps + off*512))")
      done < <(dmsetup table "$name")
      TARGETS+=("$lvdev $mnt"); how=snap
    else how=raw; fi
    log "    LV $name fs=${fstype:-none} mnt=${mnt:--} -> $how"
  done
done

PART_BYTES=$((PART_MB * 1048576))
NPARTS=$(( (DISK_BYTES + PART_BYTES - 1) / PART_BYTES ))
[ "$NPARTS" -le 10000 ] || die "$NPARTS parts > 10000 (S3 limit): use --part-mb $(( DISK_BYTES / 10000 / 1048576 + 1 )) or more"
SHM_NEED=$((PART_BYTES * THREADS / 1048576))
SHM_FREE=$(df -m --output=avail /dev/shm | tail -1 | tr -d ' ')
[ "$SHM_FREE" -gt "$SHM_NEED" ] || die "/dev/shm has $SHM_FREE MiB free, need $SHM_NEED (part-mb x threads)"
KEY="${KEYPREFIX}${NAME}/disk.raw"

if [ "$CHECK" = 1 ]; then
  log "CHECK OK: $DISK_BYTES bytes, $NPARTS parts of $PART_MB MiB -> s3://$S3_BUCKET/$KEY"
  exit 0
fi

# --- dattobd + snapshots ---------------------------------------------------------------
LOADED_BY_US=0
if [ ! -e /proc/datto-info ]; then
  ko="$PREFIX/modules/$(uname -r)/dattobd.ko"
  if [ -f "$ko" ]; then insmod "$ko" || die "insmod $ko failed"; else modprobe dattobd || die "no dattobd module"; fi
  LOADED_BY_US=1
fi
MINORS=(); declare -A SNAPDEV
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill -TERM "$1" 2>/dev/null || true; }
UPLOAD_ID=
cleanup() {
  local m i
  [ -n "${XPID:-}" ] && { killtree "$XPID"; wait "$XPID" 2>/dev/null || true; XPID=; }
  [ -n "${PPID_MON:-}" ] && kill "$PPID_MON" 2>/dev/null || true
  rm -rf "${BUF:-/dev/shm/disk2s3}" "$WORK/buf"
  for m in ${MINORS[@]+"${MINORS[@]}"}; do
    for i in 1 2 3 4 5; do dbdctl destroy "$m" >/dev/null 2>&1 && break; sleep 2; done
    [ -e "/dev/datto$m" ] && log "WARN: destroy minor $m failed — run: dbdctl destroy $m"
  done
  MINORS=()
  fb_remove
  discard_restore
  if [ "$LOADED_BY_US" = 1 ] && [ "$KEEP_MODULE" = 0 ] && [ -e /proc/datto-info ]; then rmmod dattobd 2>/dev/null || log "WARN: rmmod dattobd failed"; LOADED_BY_US=0; fi
  if [ -n "$UPLOAD_ID" ]; then
    log "aborting multipart upload $UPLOAD_ID"
    s3req DELETE "$KEY" "uploadId=$(enc_val "$UPLOAD_ID")" /dev/null >/dev/null || true
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

# --- discard (TRIM) while the snapshot exists -------------------------------------------
# dattobd does not copy blocks before a discard request (tracer_should_trace_bio skips them).
# On a disk that really zeroes discarded blocks (Yandex Cloud does; Ceph RBD in VK ignores
# small ones), a file deleted after the snapshot would read back as zeros in the copy. So:
# filesystems mounted with 'discard' are remounted 'nodiscard' and fstrim.timer is paused
# until the snapshots are gone.
NODISCARD=()
FSTRIM_STOPPED=0
discard_off() {
  local t tdev tmnt
  if systemctl is-active -q fstrim.service 2>/dev/null; then die "fstrim is running right now — wait for it to finish and start again"; fi
  if systemctl is-active -q fstrim.timer 2>/dev/null; then systemctl stop fstrim.timer && FSTRIM_STOPPED=1 && log "fstrim.timer paused"; fi
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    read -r tdev tmnt <<<"$t"
    findmnt -no OPTIONS "$tmnt" | tr ',' '\n' | grep -qx discard || continue
    mount -o remount,nodiscard "$tmnt" || die "$tmnt is mounted with 'discard' and cannot be remounted 'nodiscard' — remount it by hand and start again"
    NODISCARD+=("$tmnt"); log "$tmnt: remounted nodiscard for the transfer"
  done
}
discard_restore() {
  local m
  for m in ${NODISCARD[@]+"${NODISCARD[@]}"}; do mount -o remount,discard "$m" && log "$m: discard restored" || log "WARN: could not restore 'discard' on $m — run: mount -o remount,discard $m"; done
  NODISCARD=()
  if [ "$FSTRIM_STOPPED" = 1 ]; then systemctl start fstrim.timer && log "fstrim.timer resumed"; FSTRIM_STOPPED=0; fi
}

trap cleanup EXIT
trap 'log "signal received, cleaning up"; exit 130' INT TERM HUP
next_minor() { local m=0; while [ -e "/dev/datto$m" ]; do m=$((m+1)); done; echo $m; }

discard_off
fb_install
t0=$(date +%s); sync; log "sync before snapshots: $(( $(date +%s) - t0 )) s"
COWOPT=(); [ -n "$COW_MB" ] && COWOPT=(-f "$COW_MB")
T_SNAP=$(date -u +%FT%T.%3NZ)
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
  read -r tdev tmnt <<<"$t"; m=$(next_minor); t0=$(date +%s%N)
  dbdctl setup-snapshot ${COWOPT[@]+"${COWOPT[@]}"} "$tdev" "${tmnt%/}/$COW" "$m" || die "setup-snapshot $tdev failed"
  MINORS+=("$m"); SNAPDEV[$tdev]=/dev/datto$m
  log "snapshot $tdev ($tmnt) -> /dev/datto$m in $(( ($(date +%s%N) - t0) / 1000000 )) ms"
done
fb_remove   # the copy has the unit, the source no longer does

# --- segment map of the whole disk: "disk_off len src src_off", contiguous ------------
SEG=$WORK/segments
{
  pos=0
  while read -r doff len src soff; do
    [ "$doff" -ge "$pos" ] || die "overlapping ranges at $doff"
    [ "$doff" -gt "$pos" ] && echo "$pos $((doff - pos)) $DISK $pos"
    echo "$doff $len $src $soff"; pos=$((doff + len))
  done < <(for m in ${MAPS[@]+"${MAPS[@]}"}; do read -r tdev toff tlen doff <<<"$m"; echo "$doff $tlen ${SNAPDEV[$tdev]} $toff"; done | sort -n)
  [ "$pos" -lt "$DISK_BYTES" ] && echo "$pos $((DISK_BYTES - pos)) $DISK $pos"
} >"$SEG"
log "segments: $(wc -l <"$SEG")"

# --- multipart upload --------------------------------------------------------------------
code=$(s3retry 200 POST "$KEY" "uploads=" "$WORK/init.xml" -H "Content-Type: application/octet-stream")
[ "$code" = 200 ] || die "CreateMultipartUpload: HTTP $code $(head -c 300 "$WORK/init.xml")"
UPLOAD_ID=$(sed -n 's:.*<UploadId>\([^<]*\)</UploadId>.*:\1:p' "$WORK/init.xml")
[ -n "$UPLOAD_ID" ] || die "no UploadId in $(cat "$WORK/init.xml")"
log "multipart upload to s3://$S3_BUCKET/$KEY: $NPARTS parts, upload id ${UPLOAD_ID:0:16}..."
rm -rf "$WORK/parts" "$WORK/buf"; mkdir -p "$WORK/parts"
BUF=/dev/shm/disk2s3; rm -rf "$BUF"; mkdir -p "$BUF"; chmod 700 "$BUF"; ln -sfn "$BUF" "$WORK/buf"
export WORK BUF SEG KEY UPLOAD_ID PART_BYTES DISK_BYTES

# read [off, off+len) of the composed disk to stdout
emit_range() {
  local off=$1 len=$2 end=$(( $1 + $2 )) doff slen src soff a b
  while read -r doff slen src soff; do
    [ $((doff + slen)) -le "$off" ] && continue
    [ "$doff" -ge "$end" ] && break
    a=$(( off > doff ? off : doff )); b=$(( end < doff + slen ? end : doff + slen ))
    dd if="$src" bs=4M iflag=skip_bytes,count_bytes,fullblock skip=$((soff + a - doff)) count=$((b - a)) status=none
  done <"$SEG"
}
do_part() {
  local k=$1 off len buf md5b md5h code try etag
  off=$(( (k - 1) * PART_BYTES )); len=$(( DISK_BYTES - off < PART_BYTES ? DISK_BYTES - off : PART_BYTES ))
  buf=$BUF/p$k
  emit_range "$off" "$len" >"$buf" || { echo "part $k: read failed" >&2; return 1; }
  [ "$(stat -c %s "$buf")" = "$len" ] || { echo "part $k: short read" >&2; return 1; }
  md5b=$(openssl dgst -md5 -binary "$buf" | base64)
  md5h=$(printf '%s' "$md5b" | base64 -d | od -An -tx1 | tr -d ' \n')
  for try in $(seq 1 12); do
    # a stalled transfer (< 64 KiB/s for 60 s) is dropped and retried instead of hanging for minutes
    code=$(s3req PUT "$KEY" "partNumber=$k&uploadId=$(enc_val "$UPLOAD_ID")" "$WORK/parts/$k.resp" \
      -D "$WORK/parts/$k.hdr" -H "Content-MD5: $md5b" -H "Content-Type: application/octet-stream" \
      --speed-limit 65536 --speed-time 60 -T "$buf")
    if [ "$code" = 200 ]; then
      etag=$(awk 'tolower($1)=="etag:"{print $2}' "$WORK/parts/$k.hdr" | tr -d '\r"')
      echo "$etag $md5h" >"$WORK/parts/$k.ok"; rm -f "$buf" "$WORK/parts/$k.resp" "$WORK/parts/$k.hdr"
      return 0
    fi
    echo "$(date -u +%T) part $k try $try: HTTP $code $(head -c 200 "$WORK/parts/$k.resp" 2>/dev/null)" >&2
    echo "$try" >>"$WORK/parts/retries"
    sleep $(( try * 5 < 60 ? try * 5 : 60 ))
  done
  rm -f "$buf"; return 1
}
export -f emit_range do_part

T0=$(date +%s)
( while sleep 30; do
    n=$(ls "$WORK/parts" | grep -c '\.ok$' || true); dt=$(( $(date +%s) - T0 ))
    log "progress: $n/$NPARTS parts, $(( n * PART_BYTES / 1048576 / (dt > 0 ? dt : 1) )) MiB/s avg, retries $(cat "$WORK/parts/retries" 2>/dev/null | wc -l)"
  done ) & PPID_MON=$!
seq 1 "$NPARTS" | xargs -P "$THREADS" -n 1 bash -c 'do_part "$1"' _ & XPID=$!
wait "$XPID" || { XPID=; die "some parts failed after retries"; }
XPID=
T1=$(date +%s); kill "$PPID_MON" 2>/dev/null || true; PPID_MON=

# --- complete + verify ---------------------------------------------------------------------
{ echo "<CompleteMultipartUpload>"
  for k in $(seq 1 "$NPARTS"); do read -r etag md5h <"$WORK/parts/$k.ok"; echo "<Part><PartNumber>$k</PartNumber><ETag>\"$etag\"</ETag></Part>"; done
  echo "</CompleteMultipartUpload>"; } >"$WORK/complete.xml"
# completing can take minutes on the S3 side and the reply can be lost: retry, and if S3 says
# NoSuchUpload, the object may already be assembled — the size/ETag check below decides
for try in $(seq 1 8); do
  code=$(s3req POST "$KEY" "uploadId=$(enc_val "$UPLOAD_ID")" "$WORK/complete.resp" -H "Content-Type: application/xml" --data-binary @"$WORK/complete.xml")
  { [ "$code" = 200 ] && ! grep -q '<Error>' "$WORK/complete.resp"; } && break
  if [ "$try" -gt 1 ] && grep -q NoSuchUpload "$WORK/complete.resp" 2>/dev/null; then log "  complete: NoSuchUpload after a retry — checking the object"; break; fi
  log "  CompleteMultipartUpload: HTTP $code (try $try) $(head -c 200 "$WORK/complete.resp" 2>/dev/null)"
  [ "$try" = 8 ] && die "CompleteMultipartUpload failed"
  sleep $(( try * 10 < 60 ? try * 10 : 60 ))
done
UPLOAD_ID=
# expected multipart ETag: md5 of the concatenated binary part MD5s, "-<parts>"
exp_etag="$(printf '%b' "$(for k in $(seq 1 "$NPARTS"); do cut -d' ' -f2 "$WORK/parts/$k.ok"; done | tr -d '\n' | sed 's/../\\x&/g')" | md5sum | cut -d' ' -f1)-$NPARTS"
s3retry 200 HEAD "$KEY" "" /dev/null -I -D "$WORK/head.hdr" >/dev/null
size=$(awk 'tolower($1)=="content-length:"{print $2}' "$WORK/head.hdr" | tr -d '\r')
etag=$(awk 'tolower($1)=="etag:"{print $2}' "$WORK/head.hdr" | tr -d '\r"')
dt=$((T1 - T0)); [ $dt -gt 0 ] || dt=1
log "upload done in $dt s ($(( DISK_BYTES / 1048576 / dt )) MiB/s), retries $(cat "$WORK/parts/retries" 2>/dev/null | wc -l): size=$size etag=$etag"
[ "$size" = "$DISK_BYTES" ] && [ "$etag" = "$exp_etag" ] || die "MISMATCH: size=$size (want $DISK_BYTES) etag=$etag (want $exp_etag)"
log "OK: size and multipart ETag match"

# manifest for the restore side
{ printf '{"name":"%s","disk_bytes":%s,"part_bytes":%s,"parts":%s,"snapshot_time":"%s","source_host":"%s","version":"%s","etag":"%s","part_md5":[' \
    "$NAME" "$DISK_BYTES" "$PART_BYTES" "$NPARTS" "$T_SNAP" "$(hostname -s)" "$VERSION" "$etag"
  for k in $(seq 1 "$NPARTS"); do [ "$k" -gt 1 ] && printf ','; printf '"%s"' "$(cut -d' ' -f2 "$WORK/parts/$k.ok")"; done
  printf ']}\n'; } >"$WORK/manifest.json"
code=$(s3retry 200 PUT "${KEYPREFIX}${NAME}/manifest.json" "" /dev/null -H "Content-Type: application/json" -T "$WORK/manifest.json")
[ "$code" = 200 ] || log "WARN: manifest upload HTTP $code"
echo "s3://$S3_BUCKET/$KEY"
