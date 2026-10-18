#!/bin/bash
# disk2rx (experimental) — send a live Linux disk into a Cinder volume of the target cloud
# through a d2g receiver. Same snapshot logic as disk2glance/disk2s3: mounted ext3/ext4/xfs on
# partitions or linear LVM volumes are read from dattobd snapshots.
#
# Control goes to the d2g orchestrator (enrollment, job, commands, reports), data goes to the
# receiver that serves the job's volume, both over HTTPS with mutual TLS. The receiver keeps a
# journal of block MD5s: a restarted run skips what it already has and a later run (a new
# snapshot) sends only the blocks that changed (delta pass).
#
# Usage:
#   disk2rx --enroll --name NAME --server ctl.X.d2g --connect IP --pin 'sha256//…' --token T [--no-service]
#   disk2rx [--check] [--threads N] [--tcp-cc bbr|off] [--disk /dev/vda] [--cow-mb N] [--keep-module]   one pass now
#   disk2rx --poll                    wait for commands from the orchestrator (disk2rx-agent.service)
# The receiver address is picked from the job: its grey IP, its FIP or the orchestrator (SNI),
# whichever answers first; the orchestrator can pin one per agent (d2g agent add --path).
# For the pass the agent adds a host route to the receiver address with TCP BBR (--tcp-cc,
# D2G_TCP_CC in d2g.env): on long lossy internet paths cubic stalls at a few MiB/s per connection.
# Only traffic to that address is affected, the route is removed after the pass.
set -euo pipefail
PREFIX=${PREFIX:-/opt/disk2glance}
export PATH=$PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VERSION=$(cat "$PREFIX/VERSION" 2>/dev/null || echo dev)

CFG=/etc/disk2glance/d2g.env
PKIDIR=/etc/disk2glance/d2g
UNIT=/etc/systemd/system/disk2rx-agent.service
DISK=/dev/vda
THREADS=
TCP_CC=
COW_MB=
CHECK=0
ENROLL=0
POLL=0
SERVICE=1
KEEP_MODULE=0
A_NAME= A_SERVER= A_CONNECT= A_PIN= A_TOKEN= A_PORT=443
while [ $# -gt 0 ]; do
  case $1 in
    --enroll) ENROLL=1 ;;
    --poll) POLL=1 ;;
    --no-service) SERVICE=0 ;;
    --name) A_NAME=$2; shift ;;
    --server) A_SERVER=$2; shift ;;
    --connect) A_CONNECT=$2; shift ;;
    --port) A_PORT=$2; shift ;;
    --pin) A_PIN=$2; shift ;;
    --token) A_TOKEN=$2; shift ;;
    --check) CHECK=1 ;;
    --disk) DISK=$2; shift ;;
    --threads) THREADS=$2; shift ;;
    --tcp-cc) TCP_CC=$2; shift ;;
    --cow-mb) COW_MB=$2; shift ;;
    --keep-module) KEEP_MODULE=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
WORK=/run/disk2rx
COW=.datto_d2g
LOG=/var/log/disk2rx.log
log() { echo "$(date -u +%T) $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
# the VM's own identity: a copy of this disk (the new VM) carries the agent's certificate, but runs
# with another instance UUID — it must not act as the source
host_id() { cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr 'A-Z' 'a-z' || true; }
[ "$(id -u)" = 0 ] || die "run as root"
command -v jq >/dev/null || die "jq not found (it ships in the bundle: $PREFIX/bin/jq)"
mkdir -p "$WORK"; chmod 700 "$WORK"

# req NAME ADDR METHOD PATH OUTFILE [curl args...] -> HTTP code, or 000/curl<rc> on a transport error.
# TLS goes to NAME (certificate checked against our CA) at ADDR.
req() {
  local name=$1 addr=$2 method=$3 path=$4 out=$5 code rc; shift 5
  code=$(curl -sS --connect-timeout 20 --connect-to "$name:$D2G_PORT:$addr:$D2G_PORT" \
    --cacert "$PKIDIR/ca.crt" --cert "$PKIDIR/agent.crt" --key "$PKIDIR/agent.key" \
    -o "$out" -w '%{http_code}' -X "$method" "$@" "https://$name:$D2G_PORT$path"); rc=$?
  if [ $rc = 0 ]; then printf '%s' "$code"; else printf '000/curl%s' "$rc"; fi
}
ctlreq() { req "$D2G_SERVER" "$D2G_CONNECT" "$@"; }   # orchestrator: control
rxreq() { req "$RX_NAME" "$RX_ADDR" "$@"; }           # receiver: data
retry() {  # retry WANT ctlreq|rxreq args... -> last code
  local want=$1 fn=$2 code try; shift 2
  for try in $(seq 1 8); do
    code=$($fn "$@")
    [ "$code" = "$want" ] && { printf '%s' "$code"; return 0; }
    case $code in 401|403|404|409) break ;; esac
    log "  $1 $2: HTTP $code (try $try), retrying"
    sleep $(( try * 5 < 60 ? try * 5 : 60 ))
  done
  printf '%s' "$code"
}
rxretry() { retry "$1" rxreq "${@:2}"; }
ctlretry() { retry "$1" ctlreq "${@:2}"; }
report() {  # report ID COMMAND RC SUMMARY TAIL
  jq -n --arg id "$1" --arg c "$2" --argjson rc "$3" --arg s "$4" --arg t "$5" \
    '{id:$id, command:$c, rc:$rc, summary:$s, tail:$t}' >"$WORK/report.json"
  ctlretry 200 POST /v1/agent/report /dev/null -H 'Content-Type: application/json' --data-binary @"$WORK/report.json" >/dev/null || true
}

# --- enrollment: one-time token -> client certificate --------------------------------------
if [ "$ENROLL" = 1 ]; then
  exec 9>"$WORK/lock"; flock -n 9 || die "another disk2rx is running"
  for v in A_NAME A_SERVER A_CONNECT A_PIN A_TOKEN; do [ -n "${!v}" ] || die "--enroll needs --${v#A_}" ; done
  mkdir -p "$PKIDIR"; chmod 700 "$PKIDIR"
  base=(curl -sS --connect-timeout 30 --connect-to "$A_SERVER:$A_PORT:$A_CONNECT:$A_PORT" --pinnedpubkey "$A_PIN")
  # the CA is fetched over a connection whose server key is pinned (from the enrollment command)
  code=$("${base[@]}" -k -o "$WORK/ca.json" -w '%{http_code}' "https://$A_SERVER:$A_PORT/v1/ca") || die "cannot reach $A_SERVER at $A_CONNECT:$A_PORT (or the server key does not match the pin)"
  [ "$code" = 200 ] || die "CA download: HTTP $code"
  jq -r .ca "$WORK/ca.json" >"$PKIDIR/ca.crt"
  [ -f "$PKIDIR/agent.key" ] || openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$PKIDIR/agent.key" 2>/dev/null
  chmod 600 "$PKIDIR/agent.key"
  openssl req -new -key "$PKIDIR/agent.key" -subj "/CN=$A_NAME" -out "$WORK/agent.csr"
  dev=$(basename "$(readlink -f "$DISK")")
  [ -f "/sys/class/block/$dev/size" ] || die "$DISK is not a block device"
  . /etc/os-release
  qga=no; systemctl list-unit-files 2>/dev/null | grep -q '^qemu-guest-agent' && qga=yes
  props='{}'
  if [ -f /etc/disk2glance/props.json ]; then props=$(jq -c . /etc/disk2glance/props.json)
  else props=$(jq -nc --arg d "${ID:-linux}" --arg v "${VERSION_ID:-}" --arg q "$qga" \
      '{os_type:"linux", hw_vif_model:"virtio", os_distro:$d, os_version:$v} + (if $q=="yes" then {hw_qemu_guest_agent:"yes"} else {} end)'); fi
  mod=no; { [ -e /proc/datto-info ] || [ -f "$PREFIX/modules/$(uname -r)/dattobd.ko" ] || modinfo dattobd >/dev/null 2>&1; } && mod=yes
  jq -n --arg name "$A_NAME" --arg token "$A_TOKEN" --rawfile csr "$WORK/agent.csr" \
    --arg os "${PRETTY_NAME:-unknown}" --arg kernel "$(uname -r)" --arg host "$(hostname -s)" --arg mod "$mod" \
    --argjson disk "$(( $(cat /sys/class/block/$dev/size) * 512 ))" --argjson props "$props" --arg ver "$VERSION" --arg diskdev "$DISK" \
    '{name:$name, token:$token, csr:$csr, inventory:{os:$os, kernel:$kernel, hostname:$host, disk:$diskdev,
      disk_bytes:$disk, module:$mod, props:$props, agent_version:$ver}}' >"$WORK/enroll.json"
  code=$("${base[@]}" --cacert "$PKIDIR/ca.crt" -o "$WORK/enroll.resp" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary @"$WORK/enroll.json" "https://$A_SERVER:$A_PORT/v1/enroll") || die "enroll request failed"
  rm -f "$WORK/enroll.json"
  [ "$code" = 200 ] || die "enroll: HTTP $code $(head -c 300 "$WORK/enroll.resp")"
  jq -r .cert "$WORK/enroll.resp" >"$PKIDIR/agent.crt"
  printf 'D2G_NAME=%s\nD2G_SERVER=%s\nD2G_CONNECT=%s\nD2G_PORT=%s\nD2G_HOST_ID=%s\n' "$A_NAME" "$A_SERVER" "$A_CONNECT" "$A_PORT" "$(host_id)" >"$CFG"
  chmod 600 "$CFG"
  log "enrolled as $A_NAME at $A_SERVER ($A_CONNECT): certificate $(openssl x509 -in "$PKIDIR/agent.crt" -noout -enddate)"
  if [ "$SERVICE" = 1 ] && [ -d /etc/systemd/system ]; then
    cat >"$UNIT" <<UNITEOF
[Unit]
Description=disk2rx agent: waits for commands from the d2g orchestrator $A_SERVER
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$PREFIX/bin/disk2rx --poll
Restart=on-failure
RestartSec=15
[Install]
WantedBy=multi-user.target
UNITEOF
    # needrestart (unattended-upgrades) would restart the agent in the middle of a pass
    [ -d /etc/needrestart ] && { mkdir -p /etc/needrestart/conf.d
      echo '$nrconf{override_rc}{qr(^disk2rx-agent\.service$)} = 0;' >/etc/needrestart/conf.d/disk2rx.conf; }
    systemctl daemon-reload && systemctl enable -q --now disk2rx-agent.service
    log "disk2rx-agent.service started: the orchestrator can start passes (d2g job new / d2g agent sync)"
  fi
  exit 0
fi

if [ ! -f "$CFG" ] && [ "$POLL" = 1 ]; then
  log "not enrolled ($CFG not found): disk2rx-agent stays off"; systemctl disable -q disk2rx-agent.service 2>/dev/null || true; exit 0
fi
[ -f "$CFG" ] || die "not enrolled: $CFG not found (run disk2rx --enroll ... first)"
# shellcheck disable=SC1090
. "$CFG"
[ -n "$A_CONNECT" ] && D2G_CONNECT=$A_CONNECT
if [ -n "${D2G_HOST_ID:-}" ] && [ -n "$(host_id)" ] && [ "$(host_id)" != "$D2G_HOST_ID" ]; then
  # this disk is a copy (the new VM built from the volume): never act as the source
  mv -f "$CFG" "$CFG.copy-of-$D2G_NAME"; rm -rf "$PKIDIR"
  systemctl disable -q disk2rx-agent.service 2>/dev/null || true
  log "this VM ($(host_id)) is a copy of $D2G_NAME ($D2G_HOST_ID): agent identity removed, disk2rx-agent disabled"
  systemctl stop --no-block disk2rx-agent.service 2>/dev/null || true
  exit 0
fi
export D2G_SERVER D2G_CONNECT D2G_PORT PKIDIR

# --- poll: commands from the orchestrator ------------------------------------------------------
if [ "$POLL" = 1 ]; then
  exec 8>"$WORK/poll.lock"; flock -n 8 || die "another poller is running"
  log "disk2rx $VERSION: waiting for commands from $D2G_SERVER ($D2G_CONNECT)"
  while true; do
    code=$(ctlreq GET /v1/agent/command "$WORK/cmd.json" -m 30)
    cmd=; [ "$code" = 200 ] && cmd=$(jq -r '.command // empty' "$WORK/cmd.json" 2>/dev/null)
    if [ -n "$cmd" ]; then
      cid=$(jq -r .id "$WORK/cmd.json"); thr=$(jq -r '.threads // 8' "$WORK/cmd.json")
      case $cmd in
        sync)
          log "command $cid: pass ($thr threads), log $LOG"
          echo "===== $(date -u +%FT%TZ) pass by command $cid" >>"$LOG"
          set +e; D2G_POLLED=1 "$0" --threads "$thr" >>"$LOG" 2>&1 8>&-; rc=$?; set -e
          summary=$(grep -E 'pass [0-9]+ done|ERROR' "$LOG" | tail -1 | cut -c10-)
          report "$cid" sync "$rc" "$summary" "$(tail -n 15 "$LOG")"
          log "command $cid: rc=$rc $summary" ;;
        uninstall)
          report "$cid" uninstall 0 "removing the agent" ""
          log "command $cid: uninstall"
          systemd-run -q --unit=disk2rx-uninstall --on-active=3 "$PREFIX/install.sh" --uninstall --purge
          exit 0 ;;
        *) report "$cid" "$cmd" 64 "unknown command" "" ;;
      esac
    fi
    sleep 15
  done
fi

exec 9>"$WORK/lock"; flock -n 9 || die "another disk2rx is running"
code=$(ctlretry 200 GET /v1/agent/job "$WORK/job.json")
[ "$code" = 200 ] || die "no job from the orchestrator: HTTP $code $(head -c 300 "$WORK/job.json" 2>/dev/null)"
JOB=$(jq -r .id "$WORK/job.json"); JOB_BYTES=$(jq -r .disk_bytes "$WORK/job.json")
PART_BYTES=$(jq -r .part_bytes "$WORK/job.json"); BLOCK_BYTES=$(jq -r .block_bytes "$WORK/job.json"); PASS=$(( $(jq -r .pass_no "$WORK/job.json") + 1 ))
THREADS=${THREADS:-$(jq -r '.threads // 8' "$WORK/job.json")}
RX_NAME=$(jq -r .receiver.name "$WORK/job.json"); RX_ADDR=; RX_PATH=
# first address of the receiver that answers: grey (Direct Connect / same network), its FIP, the orchestrator
while read -r kind addr; do
  [ "$(req "$RX_NAME" "$addr" GET /v1/ping /dev/null -m 10)" = 200 ] && { RX_ADDR=$addr; RX_PATH=$kind; break; }
  log "  receiver $RX_NAME via $kind $addr: no answer"
done < <(jq -r '.receiver.addrs[] | "\(.[0]) \(.[1])"' "$WORK/job.json")
[ -n "$RX_ADDR" ] || die "receiver $RX_NAME is not reachable on any of its addresses"
export RX_NAME RX_ADDR
log "disk2rx $VERSION, kernel $(uname -r), disk $DISK: job $JOB pass $PASS -> $RX_NAME via $RX_PATH $RX_ADDR, part $((PART_BYTES / 1048576)) MiB, $THREADS threads"

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


NPARTS=$(( (DISK_BYTES + PART_BYTES - 1) / PART_BYTES ))
[ "$DISK_BYTES" = "$JOB_BYTES" ] || die "disk is $DISK_BYTES bytes, the job expects $JOB_BYTES (disk resized since enrollment?)"
SHM_NEED=$((PART_BYTES * THREADS / 1048576))
SHM_FREE=$(df -m --output=avail /dev/shm | tail -1 | tr -d ' ')
[ "$SHM_FREE" -gt "$SHM_NEED" ] || die "/dev/shm has $SHM_FREE MiB free, need $SHM_NEED (part size x threads): use fewer --threads"
if [ "$CHECK" = 1 ]; then
  log "CHECK OK: $DISK_BYTES bytes, $NPARTS parts of $((PART_BYTES / 1048576)) MiB -> job $JOB"
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
# leftovers of a run killed with -9 (we hold the lock, so no other run owns them): our snapshots
# (COW file $COW), the first-boot unit, a paused fstrim.timer
for m in $(jq -r --arg c "/$COW" '.devices[]? | select(.cow_file == $c) | .minor' /proc/datto-info 2>/dev/null); do
  dbdctl destroy "$m" >/dev/null 2>&1 && log "removed snapshot /dev/datto$m left by a killed run" || die "cannot remove stale snapshot /dev/datto$m"
done
rm -f /etc/systemd/system/disk2glance-cowclean.service /etc/systemd/system/multi-user.target.wants/disk2glance-cowclean.service
if systemctl is-enabled -q fstrim.timer 2>/dev/null && ! systemctl is-active -q fstrim.timer; then systemctl start fstrim.timer && log "fstrim.timer was left stopped by a killed run — started"; fi
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill -TERM "$1" 2>/dev/null || true; }
# snapshot sets of the disk2glance dattobd build: thaw whatever is still held (idempotent)
HOLD=/sys/module/dattobd/parameters
hold_release() {
  [ "${SNAP_SET:-0}" = 1 ] || return 0
  echo 1 >"$HOLD/release_held" 2>/dev/null; echo 0 >"$HOLD/hold_thaw" 2>/dev/null; SNAP_SET=2
}
cleanup() {
  local m i
  hold_release
  [ -n "${XPID:-}" ] && { killtree "$XPID"; wait "$XPID" 2>/dev/null || true; XPID=; }
  [ -n "${PPID_MON:-}" ] && kill "$PPID_MON" 2>/dev/null || true
  rm -rf "${BUF:-/dev/shm/disk2rx}" "$WORK/buf"
  for m in ${MINORS[@]+"${MINORS[@]}"}; do
    for i in 1 2 3 4 5; do dbdctl destroy "$m" >/dev/null 2>&1 && break; sleep 2; done
    [ -e "/dev/datto$m" ] && log "WARN: destroy minor $m failed — run: dbdctl destroy $m"
  done
  MINORS=()
  fb_remove
  discard_restore
  cc_off
  if [ "$LOADED_BY_US" = 1 ] && [ "$KEEP_MODULE" = 0 ] && [ -e /proc/datto-info ]; then rmmod dattobd 2>/dev/null || log "WARN: rmmod dattobd failed"; LOADED_BY_US=0; fi
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
Description=disk2glance: delete dattobd COW files and the disk2rx agent identity copied with the disk
After=local-fs.target
Before=disk2rx-agent.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in$files; do [ -e "\$\$f" ] && { chattr -i "\$\$f" 2>/dev/null; rm -f "\$\$f"; }; done; rm -f $FB_LINK $FB_UNIT'
ExecStart=/bin/sh -c 'rm -f /etc/systemd/system/multi-user.target.wants/disk2rx-agent.service; [ -f $CFG ] && mv -f $CFG $CFG.copy; rm -rf $PKIDIR; true'
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

# --- TCP congestion control towards the receiver only ------------------------------------
CC_ROUTE=
cc_on() {
  local want=${TCP_CC:-${D2G_TCP_CC:-bbr}} avail=/proc/sys/net/ipv4/tcp_available_congestion_control r gw dev
  [ "$want" = off ] && return 0
  grep -qw "$want" "$avail" 2>/dev/null || modprobe "tcp_$want" 2>/dev/null || true
  grep -qw "$want" "$avail" 2>/dev/null || { log "TCP $want is not available in this kernel: system default"; return 0; }
  [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = "$want" ] && return 0
  r=$(ip -4 route show "$RX_ADDR/32" 2>/dev/null || true)
  if [ -n "$r" ]; then   # ours from a killed run: reuse and remove; someone else's: leave it
    grep -q "congctl $want" <<<"$r" && CC_ROUTE="$RX_ADDR/32" || log "route to $RX_ADDR exists: congestion control left as is"
    return 0
  fi
  r=$(ip -4 route get "$RX_ADDR" 2>/dev/null | head -1 || true)
  gw=$(sed -n 's/.* via \([0-9.]*\).*/\1/p' <<<"$r"); dev=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$r")
  [ -n "$dev" ] || return 0
  if ip route add "$RX_ADDR/32" ${gw:+via "$gw"} dev "$dev" congctl "$want" 2>/dev/null; then
    CC_ROUTE="$RX_ADDR/32"; log "TCP $want towards $RX_ADDR only (host route, removed after the pass)"
  fi
}
cc_off() { [ -n "$CC_ROUTE" ] && ip route del "$CC_ROUTE" 2>/dev/null; CC_ROUTE=; }

trap cleanup EXIT
trap 'log "signal received, cleaning up"; exit 130' INT TERM HUP
next_minor() { local m=0; while [ -e "/dev/datto$m" ]; do m=$((m+1)); done; echo $m; }

discard_off
cc_on
# a COW file left by a pass interrupted by a reboot: our stale snapshots are destroyed above and we
# hold the lock, so nothing uses it now
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
  read -r tdev tmnt <<<"$t"; f="${tmnt%/}/$COW"
  [ -e "$f" ] && { chattr -i "$f" 2>/dev/null; rm -f "$f" && log "removed $f left by an interrupted pass"; }
done
fb_install
t0=$(date +%s); sync; log "sync before snapshots: $(( $(date +%s) - t0 )) s"
COWOPT=(); [ -n "$COW_MB" ] && COWOPT=(-f "$COW_MB")
# Snapshot set: with the disk2glance build of dattobd (hold_thaw, patches/dattobd-hold-thaw.patch)
# each filesystem stays frozen after its snapshot until all are taken, so the snapshots are one
# point in time; writes wait for the whole set (0.2-0.3 s for five filesystems). The root
# filesystem goes last and nothing is written to disk until the release. If the set takes longer
# than D2G_SNAP_HOLD_MS, the module thaws everything itself: the pass goes on, but the snapshots
# are taken one after another, as with a stock dattobd.
snap_order=()
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do read -r tdev tmnt <<<"$t"; [ "$tmnt" = / ] || snap_order+=("$t"); done
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do read -r tdev tmnt <<<"$t"; [ "$tmnt" = / ] && snap_order+=("$t"); done
SNAP_SET=0; snap_log=()
if [ ${#snap_order[@]} -gt 1 ] && [ -w "$HOLD/hold_thaw" ]; then
  SNAP_SET=1; echo "${D2G_SNAP_HOLD_MS:-3000}" >"$HOLD/hold_timeout_ms"; echo 1 >"$HOLD/hold_thaw"
fi
T_SNAP=$(date -u +%FT%T.%3NZ); ts0=$(date +%s%N)
for t in ${snap_order[@]+"${snap_order[@]}"}; do
  read -r tdev tmnt <<<"$t"; m=$(next_minor); t0=$(date +%s%N)
  dbdctl setup-snapshot ${COWOPT[@]+"${COWOPT[@]}"} "$tdev" "${tmnt%/}/$COW" "$m" || { hold_release; die "setup-snapshot $tdev failed"; }
  MINORS+=("$m"); SNAPDEV[$tdev]=/dev/datto$m
  snap_log+=("snapshot $tdev ($tmnt) -> /dev/datto$m in $(( ($(date +%s%N) - t0) / 1000000 )) ms")
done
held=$(cat "$HOLD/release_held" 2>/dev/null || echo 0); hold_release
for l in ${snap_log[@]+"${snap_log[@]}"}; do log "$l"; done
if [ "$SNAP_SET" != 0 ]; then
  ms=$(( ($(date +%s%N) - ts0) / 1000000 ))
  if [ "$held" = ${#snap_order[@]} ]; then log "snapshot set of ${#snap_order[@]} filesystems, one point in time; writes waited $ms ms"
  else log "WARN: snapshot set took $ms ms > D2G_SNAP_HOLD_MS=${D2G_SNAP_HOLD_MS:-3000}: dattobd thawed the filesystems early, the snapshots are not one point in time"; fi
elif [ ${#snap_order[@]} -gt 1 ]; then
  log "WARN: this dattobd has no snapshot sets (hold_thaw): ${#snap_order[@]} snapshots taken one after another, not one point in time"
fi
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
} >"$SEG.raw"
# The COW files are part of the copy (deleted there at first boot), but their content is of no use:
# their extents go as zeros, so they cost nothing on the wire and do not show up in every delta.
# filefrag gives physical extents in filesystem blocks; MAPS maps the filesystem onto the disk.
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
  read -r tdev tmnt <<<"$t"
  f="${tmnt%/}/$COW"; [ -f "$f" ] || continue
  bs=$(filefrag -v "$f" 2>/dev/null | sed -n 's/.*blocks of \([0-9]*\) bytes.*/\1/p'); [ -n "$bs" ] || continue
  filefrag -v "$f" | awk '/^ *[0-9]+: *[0-9]+\.\./ { gsub(/\.\./, " "); gsub(/:/, " "); print $4, $5 }' |
  while read -r pa pb; do
    fo=$((pa * bs)); fl=$(( (pb - pa + 1) * bs ))
    for m in ${MAPS[@]+"${MAPS[@]}"}; do
      read -r mdev moff mlen mdoff <<<"$m"; [ "$mdev" = "$tdev" ] || continue
      a=$(( fo > moff ? fo : moff )); b=$(( fo + fl < moff + mlen ? fo + fl : moff + mlen ))
      [ "$a" -lt "$b" ] && echo "$((mdoff + a - moff)) $((b - a))"
    done
  done
done | sort -n >"$WORK/zero_ranges"
# cut the zero ranges out of the segments: "disk_off len zero 0"
awk 'NR == FNR { zs[++nz] = $1; ze[nz] = $1 + $2; next }
     { o = $1; e = $1 + $2
       for (i = 1; i <= nz && o < e; i++) {
         if (ze[i] <= o || zs[i] >= e) continue
         if (zs[i] > o) { printf "%.0f %.0f %s %.0f\n", o, zs[i] - o, $3, $4 + o - $1; o = zs[i] }
         z = (ze[i] < e ? ze[i] : e); printf "%.0f %.0f zero 0\n", o, z - o; o = z
       }
       if (o < e) printf "%.0f %.0f %s %.0f\n", o, e - o, $3, $4 + o - $1 }' "$WORK/zero_ranges" "$SEG.raw" >"$SEG"
log "segments: $(wc -l <"$SEG"), COW files sent as zeros: $(awk '{s += $2} END {printf "%.0f", s / 1048576}' "$WORK/zero_ranges") MiB"

# --- transfer ----------------------------------------------------------------------------------
code=$(rxretry 200 POST "/v1/jobs/$JOB/start" "$WORK/start.resp" -H 'Content-Type: application/json' \
  --data-binary "{\"snapshot_time\":\"$T_SNAP\"}")
[ "$code" = 200 ] || die "start: HTTP $code $(head -c 300 "$WORK/start.resp" 2>/dev/null)"
code=$(rxretry 200 GET "/v1/jobs/$JOB/parts" "$WORK/journal.json")
[ "$code" = 200 ] || die "journal: HTTP $code"
rm -rf "$WORK/parts" "$WORK/buf"; mkdir -p "$WORK/parts"
jq -r '.parts | to_entries[] | "\(.key) \(.value)"' "$WORK/journal.json" | while read -r k h; do echo "$h" >"$WORK/parts/$k.have"; done
HAVE=$(ls "$WORK/parts" | grep -c '\.have$' || true)
log "receiver already has $HAVE/$NPARTS parts"
BUF=/dev/shm/disk2rx; rm -rf "$BUF"; mkdir -p "$BUF"; chmod 700 "$BUF"; ln -sfn "$BUF" "$WORK/buf"
ZMD5_BLOCK=$(head -c "$BLOCK_BYTES" /dev/zero | md5sum | cut -d' ' -f1)
export WORK BUF SEG JOB PART_BYTES BLOCK_BYTES DISK_BYTES NPARTS ZMD5_BLOCK

# read [off, off+len) of the composed disk to stdout
emit_range() {
  local off=$1 len=$2 end=$(( $1 + $2 )) doff slen src soff a b
  while read -r doff slen src soff; do
    [ $((doff + slen)) -le "$off" ] && continue
    [ "$doff" -ge "$end" ] && break
    a=$(( off > doff ? off : doff )); b=$(( end < doff + slen ? end : doff + slen ))
    if [ "$src" = zero ]; then head -c $((b - a)) /dev/zero
    else dd if="$src" bs=4M iflag=skip_bytes,count_bytes,fullblock skip=$((soff + a - doff)) count=$((b - a)) status=none; fi
  done <"$SEG"
}
# do_part K: read the part and hash its blocks (a part = 16 blocks). Blocks the receiver already
# has with the same MD5 are skipped; zero blocks go as a marker without data; the rest go in one
# request: body = the changed blocks one after another, X-D2G-Blocks = "index:md5,..." in body order.
do_part() {
  local k=$1 off len buf cur have i h n code try body nb blen zmd5
  off=$(( (k - 1) * PART_BYTES )); len=$(( DISK_BYTES - off < PART_BYTES ? DISK_BYTES - off : PART_BYTES ))
  buf=$BUF/p$k
  emit_range "$off" "$len" >"$buf" || { echo "part $k: read failed" >&2; return 1; }
  [ "$(stat -c %s "$buf")" = "$len" ] || { echo "part $k: short read" >&2; return 1; }
  mapfile -t cur < <(split -b "$BLOCK_BYTES" --filter='md5sum' "$buf" | cut -c1-32)
  have=(); [ -f "$WORK/parts/$k.have" ] && IFS=, read -r -a have <"$WORK/parts/$k.have"
  local data=() zero=() hdr=
  n=${#cur[@]}
  for ((i = 0; i < n; i++)); do
    [ ${#have[@]} = "$n" ] && [ "${have[i]}" = "${cur[i]}" ] && continue
    blen=$(( len - i * BLOCK_BYTES < BLOCK_BYTES ? len - i * BLOCK_BYTES : BLOCK_BYTES ))
    zmd5=$ZMD5_BLOCK; [ "$blen" != "$BLOCK_BYTES" ] && zmd5=$(head -c "$blen" /dev/zero | md5sum | cut -c1-32)
    if [ "${cur[i]}" = "$zmd5" ]; then zero+=("$i"); else data+=("$i:${cur[i]}"); fi
  done
  if [ ${#data[@]} = 0 ] && [ ${#zero[@]} = 0 ]; then
    (IFS=,; echo "${cur[*]}") >"$WORK/parts/$k.ok"; rm -f "$buf"; return 0
  fi
  body=$buf
  if [ ${#data[@]} -lt "$n" ] && [ ${#data[@]} -gt 0 ]; then
    body=$buf.d; : >"$body"
    for h in "${data[@]}"; do dd if="$buf" of="$body" bs="$BLOCK_BYTES" skip="${h%%:*}" count=1 oflag=append conv=notrunc status=none; done
  elif [ ${#data[@]} = 0 ]; then body=/dev/null; fi
  nb=$(stat -c %s "$body" 2>/dev/null || echo 0); [ "$body" = /dev/null ] && nb=0
  local args=(-H "Content-Type: application/octet-stream" --speed-limit 65536 --speed-time 60)
  [ ${#data[@]} -gt 0 ] && args+=(-H "X-D2G-Blocks: $(IFS=,; echo "${data[*]}")" -T "$body")
  [ ${#zero[@]} -gt 0 ] && args+=(-H "X-D2G-Zero-Blocks: $(IFS=,; echo "${zero[*]}")")
  [ ${#data[@]} = 0 ] && args+=(-H "Content-Length: 0" --data-binary "")
  for try in $(seq 1 12); do
    code=$(rxreq PUT "/v1/jobs/$JOB/parts/$k" "$WORK/parts/$k.resp" "${args[@]}")
    if [ "$code" = 200 ]; then
      (IFS=,; echo "${cur[*]}") >"$WORK/parts/$k.ok"; echo "$nb ${#data[@]} ${#zero[@]}" >"$WORK/parts/$k.sent"
      rm -f "$buf" "$buf.d" "$WORK/parts/$k.resp"; return 0
    fi
    if [ "$code" = 503 ]; then echo x >>"$WORK/parts/busy"; sleep 1; continue; fi   # receiver busy: not an error
    echo "$(date -u +%T) part $k try $try: HTTP $code $(head -c 200 "$WORK/parts/$k.resp" 2>/dev/null)" >&2
    echo "$try" >>"$WORK/parts/retries"
    case $code in 401|403|404) break ;; 409) rm -f "$WORK/parts/$k.have"; break ;; esac
    sleep $(( try * 5 < 60 ? try * 5 : 60 ))
  done
  rm -f "$buf" "$buf.d"; return 1
}
export -f emit_range do_part req rxreq

T0=$(date +%s)
( exec 9>&-; while sleep 30; do   # fd 9 = lock: a leftover sleep must not hold it
    n=$(ls "$WORK/parts" | grep -c '\.ok$' || true); dt=$(( $(date +%s) - T0 ))
    b=$(cat "$WORK"/parts/*.sent 2>/dev/null | awk '{s += $1} END {printf "%.0f", s / 1048576}')
    log "progress: $n/$NPARTS parts checked, $b MiB sent, $(( b / (dt > 0 ? dt : 1) )) MiB/s, retries $(cat "$WORK/parts/retries" 2>/dev/null | wc -l)"
  done ) & PPID_MON=$!
for round in 1 2 3; do
  seq 1 "$NPARTS" | while read -r k; do [ -f "$WORK/parts/$k.ok" ] || echo "$k"; done >"$WORK/todo"
  [ -s "$WORK/todo" ] || break
  xargs -P "$THREADS" -n 1 bash -c 'do_part "$1"' _ <"$WORK/todo" & XPID=$!
  wait "$XPID" || log "round $round: some parts failed, $(seq 1 "$NPARTS" | while read -r k; do [ -f "$WORK/parts/$k.ok" ] || echo x; done | wc -l) left"
  XPID=
  # the receiver confirms the whole disk; parts it lacks (or has with another MD5) are sent again
  # per part: MD5 of its block list "md5,md5,..." (the receiver computes the same from its journal)
  { printf '{"snapshot_time":"%s","sent":%s,"part_md5":[' "$T_SNAP" "$(ls "$WORK/parts" | grep -c '\.sent$' || true)"
    for k in $(seq 1 "$NPARTS"); do [ "$k" -gt 1 ] && printf ','; printf '"%s"' "$(tr -d '\n' <"$WORK/parts/$k.ok" 2>/dev/null | md5sum | cut -c1-32)"; done
    printf ']}\n'; } >"$WORK/complete.json"
  missing=$(seq 1 "$NPARTS" | while read -r k; do [ -f "$WORK/parts/$k.ok" ] || echo x; done | wc -l)
  [ "$missing" -gt 0 ] && continue
  code=$(rxretry 200 POST "/v1/jobs/$JOB/complete" "$WORK/complete.resp" -H 'Content-Type: application/json' --data-binary @"$WORK/complete.json")
  [ "$code" = 200 ] && { DONE=1; break; }
  [ "$code" = 409 ] || die "complete: HTTP $code $(head -c 300 "$WORK/complete.resp")"
  log "receiver lacks $(jq -r .count "$WORK/complete.resp") parts — sending them again"
  for k in $(jq -r '.parts[]' "$WORK/complete.resp"); do rm -f "$WORK/parts/$k.ok" "$WORK/parts/$k.have"; done
done
T1=$(date +%s); kill "$PPID_MON" 2>/dev/null || true; PPID_MON=
[ "${DONE:-0}" = 1 ] || die "transfer incomplete after 3 rounds"
dt=$((T1 - T0)); [ $dt -gt 0 ] || dt=1
read -r SENTB DBLK ZBLK SENT < <(cat "$WORK"/parts/*.sent 2>/dev/null | awk '{b += $1; d += $2; z += $3; n++} END {printf "%.0f %d %d %d\n", b, d, z, n}')
log "pass $PASS done in $dt s: $SENT of $NPARTS parts changed, blocks: $DBLK sent, $ZBLK zero; $(( SENTB / 1048576 )) MiB on the wire ($(( SENTB / 1048576 / dt )) MiB/s), disk read $(( DISK_BYTES / 1048576 / dt )) MiB/s, retries $(cat "$WORK/parts/retries" 2>/dev/null | wc -l), busy $(cat "$WORK/parts/busy" 2>/dev/null | wc -l)"
log "OK: receiver confirmed all $NPARTS parts, snapshot $T_SNAP"
# a pass run by hand is reported too (the poller reports its own runs)
[ -n "${D2G_POLLED:-}" ] || report "" pass 0 "pass $PASS done in $dt s: $SENT parts changed, $(( SENTB / 1048576 )) MiB sent via $RX_PATH" ""
