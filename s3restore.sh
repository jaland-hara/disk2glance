#!/bin/bash
# s3restore (experimental) — write a disk2s3 image from S3 onto a block device (an empty
# Cinder volume attached to a helper VM). Parts are fetched in parallel with ranged GETs,
# each is checked against the MD5 from manifest.json, all-zero parts are not written
# (a new Ceph volume already reads as zeros). --verify re-reads the device afterwards.
#
# Usage: s3restore --key PREFIX/NAME --dev /dev/vdb [--s3env FILE] [--threads 16] [--verify]
set -euo pipefail
S3ENV=/etc/disk2glance/s3.env; THREADS=16; VERIFY=0; KEYBASE=; DEV=
while [ $# -gt 0 ]; do
  case $1 in
    --s3env) S3ENV=$2; shift ;; --key) KEYBASE=${2%/}; shift ;; --dev) DEV=$2; shift ;;
    --threads) THREADS=$2; shift ;; --verify) VERIFY=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;; *) echo "unknown option $1" >&2; exit 64 ;;
  esac; shift
done
log() { echo "$(date -u +%T) $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -n "$KEYBASE" ] && [ -b "$DEV" ] || die "need --key and --dev <block device>"
grep -q "^$(readlink -f "$DEV") " /proc/mounts && die "$DEV is mounted"
WORK=/run/s3restore; rm -rf "$WORK"; mkdir -p "$WORK/ok"; chmod 700 "$WORK"
BUF=/dev/shm/s3restore; rm -rf "$BUF"; mkdir -p "$BUF"; chmod 700 "$BUF"
trap 'rm -rf "$BUF"' EXIT
# shellcheck disable=SC1090
. "$S3ENV"
S3_REGION=${S3_REGION:-ru-msk}; S3_ENDPOINT=${S3_ENDPOINT%/}; S3_HOST=${S3_ENDPOINT#*://}; S3_HOST=${S3_HOST%%/*}
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

for try in $(seq 1 8); do
  code=$(s3req GET "$KEYBASE/manifest.json" "" "$WORK/manifest.json"); [ "$code" = 200 ] && break
  log "manifest: HTTP $code (try $try)"; [ "$try" = 8 ] && die "manifest: HTTP $code"; sleep $((try * 5))
done
read -r DISK_BYTES PART_BYTES NPARTS SNAP < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["disk_bytes"], m["part_bytes"], m["parts"], m["snapshot_time"])' "$WORK/manifest.json")
python3 -c 'import json,sys; [print(i+1, h) for i,h in enumerate(json.load(open(sys.argv[1]))["part_md5"])]' "$WORK/manifest.json" >"$WORK/md5"
DEV_BYTES=$(blockdev --getsize64 "$DEV")
[ "$DEV_BYTES" -ge "$DISK_BYTES" ] || die "$DEV is $DEV_BYTES bytes, image is $DISK_BYTES"
log "image s3://$S3_BUCKET/$KEYBASE/disk.raw: $DISK_BYTES bytes, $NPARTS parts of $((PART_BYTES/1048576)) MiB, snapshot $SNAP -> $DEV ($THREADS threads)"
KEY=$KEYBASE/disk.raw
export WORK BUF KEY DEV PART_BYTES DISK_BYTES

get_part() {
  local k=$1 off len buf want got code try
  off=$(( (k - 1) * PART_BYTES )); len=$(( DISK_BYTES - off < PART_BYTES ? DISK_BYTES - off : PART_BYTES ))
  want=$(sed -n "${k}p" "$WORK/md5" | cut -d' ' -f2); buf=$BUF/p$k
  for try in $(seq 1 12); do
    code=$(s3req GET "$KEY" "" "$buf" -H "Range: bytes=$off-$((off + len - 1))" --speed-limit 65536 --speed-time 60)
    got=$(md5sum "$buf" 2>/dev/null | cut -d' ' -f1)
    if [ "$code" = 206 ] && [ "$got" = "$want" ]; then
      if cmp -s -n "$len" "$buf" /dev/zero; then echo zero >"$WORK/ok/$k"
      else dd if="$buf" of="$DEV" bs=4M seek="$off" oflag=seek_bytes,direct conv=notrunc status=none || { echo "part $k: write failed" >&2; rm -f "$buf"; return 1; }
        echo data >"$WORK/ok/$k"; fi
      rm -f "$buf"; return 0
    fi
    echo "$(date -u +%T) part $k try $try: HTTP $code md5 ${got:-none} want $want" >&2
    echo "$k" >>"$WORK/retries"; sleep $(( try * 5 < 60 ? try * 5 : 60 ))
  done
  rm -f "$buf"; return 1
}
verify_part() {
  local k=$1 off len want got
  off=$(( (k - 1) * PART_BYTES )); len=$(( DISK_BYTES - off < PART_BYTES ? DISK_BYTES - off : PART_BYTES ))
  want=$(sed -n "${k}p" "$WORK/md5" | cut -d' ' -f2)
  got=$(dd if="$DEV" bs=4M iflag=skip_bytes,count_bytes,direct skip="$off" count="$len" status=none | md5sum | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "VERIFY part $k: $got != $want" >&2; return 1; }
}
export -f get_part verify_part

T0=$(date +%s)
( while sleep 30; do n=$(ls "$WORK/ok" | wc -l); dt=$(( $(date +%s) - T0 ))
    log "progress: $n/$NPARTS parts, $(( n * PART_BYTES / 1048576 / (dt > 0 ? dt : 1) )) MiB/s avg, retries $(cat "$WORK/retries" 2>/dev/null | wc -l)"; done ) & MON=$!
seq 1 "$NPARTS" | xargs -P "$THREADS" -n 1 bash -c 'get_part "$1"' _ || { kill $MON; die "some parts failed after retries"; }
kill $MON 2>/dev/null || true
sync; blockdev --flushbufs "$DEV"
dt=$(( $(date +%s) - T0 )); [ $dt -gt 0 ] || dt=1
log "restore done in $dt s ($(( DISK_BYTES / 1048576 / dt )) MiB/s): $(grep -l data "$WORK"/ok/* | wc -l) parts written, $(grep -l zero "$WORK"/ok/* | wc -l) zero parts skipped, retries $(cat "$WORK/retries" 2>/dev/null | wc -l)"
if [ "$VERIFY" = 1 ]; then
  T0=$(date +%s)
  seq 1 "$NPARTS" | xargs -P "$THREADS" -n 1 bash -c 'verify_part "$1"' _ || die "VERIFY FAILED"
  log "verify OK: all $NPARTS parts on $DEV match manifest MD5 ($(( $(date +%s) - T0 )) s)"
fi
echo OK
