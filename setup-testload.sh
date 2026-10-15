#!/bin/bash
# Test load for disk2glance runs: PostgreSQL + pgbench (rate-limited) + a timestamp
# writer (1 line/s to a file with fsync and 1 row/s into PostgreSQL).
# Works on Ubuntu/Debian (apt) and RED OS / RHEL-likes (dnf). Run as root.
set -euo pipefail
RATE=${RATE:-40}
SCALE=${SCALE:-50}

if command -v apt-get >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib >/dev/null
  PGSVC=postgresql
else
  "$(command -v dnf || command -v yum)" -y -q install postgresql-server postgresql-contrib >/dev/null
  [ -f /var/lib/pgsql/data/PG_VERSION ] || postgresql-setup --initdb >/dev/null 2>&1 || postgresql-setup initdb >/dev/null
  PGSVC=postgresql
  systemctl enable --now postgresql >/dev/null 2>&1
fi
PGBENCH=$(command -v pgbench || ls /usr/lib/postgresql/*/bin/pgbench /usr/pgsql-*/bin/pgbench 2>/dev/null | head -1)
# pgbench < 9.4 (CentOS 7 ships 9.2) has no --rate/--progress: fall back to 1 client, unthrottled
if "$PGBENCH" --help 2>&1 | grep -q -- '--rate'; then BENCHOPTS="-c 4 -j 2 -R $RATE -P 30"
else BENCHOPTS="-c 1 -j 1"; fi

cd /
sudo -u postgres psql -qc "create database bench" 2>/dev/null || true
sudo -u postgres "$PGBENCH" -i -s "$SCALE" bench 2>&1 | tail -1   # no -q: pgbench 9.2
sudo -u postgres psql -q bench -c "create table if not exists ticks(seq bigint primary key, ts timestamptz default now())"

mkdir -p /var/lib/tsw
cat >/usr/local/bin/tsw.sh <<'S'
#!/bin/bash
# timestamp writer: 1 line/sec to file (fsync) + 1 row/sec to PostgreSQL
cd /
f=/var/lib/tsw/ticks.log
seq=$(( $(tail -n1 $f 2>/dev/null | cut -d' ' -f1) + 0 ))
while true; do
  seq=$((seq+1)); ts=$(date -u +%FT%T.%3NZ)
  echo "$seq $ts" >> $f; sync $f
  sudo -u postgres psql -q bench -c "insert into ticks(seq) values ($seq)" >/dev/null
  sleep 1
done
S
chmod +x /usr/local/bin/tsw.sh

cat >/etc/systemd/system/tsw.service <<S
[Unit]
Description=Timestamp writer (file + PostgreSQL)
After=$PGSVC.service
[Service]
ExecStart=/usr/local/bin/tsw.sh
Restart=always
[Install]
WantedBy=multi-user.target
S
cat >/etc/systemd/system/pgbench-load.service <<S
[Unit]
Description=Continuous pgbench load
After=$PGSVC.service
[Service]
User=postgres
WorkingDirectory=/tmp
ExecStart=$PGBENCH $BENCHOPTS -T 31536000 bench
Restart=always
[Install]
WantedBy=multi-user.target
S
systemctl daemon-reload
systemctl enable --now tsw.service pgbench-load.service
sleep 15
systemctl is-active tsw pgbench-load
tail -1 /var/lib/tsw/ticks.log
