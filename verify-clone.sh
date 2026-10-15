#!/bin/bash
# Verify a clone booted from a disk2glance image: fs, PostgreSQL recovery, ticks, data invariants.
# Usage: verify-clone.sh <snapshot-time-UTC, e.g. 2026-10-15T20:53:39.584Z>   (run as root)
SNAP=$1
cd /
echo "host=$(hostname) kernel=$(uname -r) boot=$(uptime -s)"
echo "=== fs at boot:"; journalctl -k -b --no-pager | grep -E "EXT4-fs \(vd|XFS \(vd" | grep -v datto | head -4
PGLOG=$(ls -t /var/lib/pgsql/data/log/*.log /var/lib/pgsql/data/pg_log/*.log /var/log/postgresql/*.log 2>/dev/null | head -1)
pg_up() { sudo -u postgres psql -Atqc 'select 1' >/dev/null 2>&1; }   # pg_isready needs PostgreSQL >= 9.3
for i in $(seq 1 60); do pg_up && break; sleep 10; done
pg_up && echo "PostgreSQL accepting connections" || echo "PostgreSQL NOT accepting connections"
echo "=== PostgreSQL recovery ($PGLOG):"
grep -hE "interrupted|redo (starts|done)|end-of-recovery|ready to accept" "$PGLOG" | tail -4 | cut -c1-200
echo "=== ticks (snapshot $SNAP):"
echo "file: $(awk -v s="$SNAP" '$2 < s' /var/lib/tsw/ticks.log | tail -1)  | first after: $(awk -v s="$SNAP" '$2 > s' /var/lib/tsw/ticks.log | head -1)"
echo "db:   $(sudo -u postgres psql -Atq bench -c "select max(seq), max(ts) from ticks where ts < '$SNAP'::timestamptz + interval '1 minute'")"
echo "=== amcheck:"
if sudo -u postgres psql -Atq bench -c "select 1 from pg_available_extensions where name='amcheck'" | grep -q 1; then
  sudo -u postgres psql -Atq bench -c "create extension if not exists amcheck" -c "select c.relname, bt_index_check(c.oid, true) from pg_class c where c.relkind='i' and (c.relname like 'pgbench%' or c.relname='ticks_pkey')" 2>&1 | tr '\n' ' '; echo
else
  echo "amcheck not available (PostgreSQL < 10) — full scan of tables and indexes instead:"
  sudo -u postgres psql -Atq bench -c "set enable_seqscan=off; select count(*) from pgbench_accounts where aid > 0" -c "set enable_seqscan=on; set enable_indexscan=off; set enable_bitmapscan=off; select count(*) from pgbench_accounts" 2>&1 | tr '\n' ' '; echo
fi
echo "=== pgbench invariant (accounts = branches = tellers):"
sudo -u postgres psql -Atq bench -c "select (select sum(abalance) from pgbench_accounts),(select sum(bbalance) from pgbench_branches),(select sum(tbalance) from pgbench_tellers)"
