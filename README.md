# disk2glance

Agent that runs **inside a live Linux VM** and streams its whole disk into an
OpenStack **Glance** image (raw), while applications keep writing. A new VM is
then booted from that image (e.g. in VK Cloud). No helper VM, no temp files.

## How it works

- Mounted ext4/xfs partitions are read from [dattobd](https://github.com/datto/dattobd)
  copy-on-write snapshots (crash-consistent, taken back to back).
- Partition table, BIOS boot / EFI partitions, gaps and the GPT backup header are read raw from the disk.
- Segments are concatenated in disk order into one raw stream and sent with a chunked
  `PUT /v2/images/{id}/file`; size and checksum are verified against Glance (sha512 when
  Glance has multihash, else md5 `checksum`).

## Files

| File | Purpose |
|---|---|
| `disk2glance.sh` | the agent (`/usr/local/sbin/disk2glance [image-name]`) |
| `install-dattobd.sh` | builds dattobd 0.12.2 (as root) and installs it via DKMS |
| `setup-testload.sh` | test load: PostgreSQL + pgbench + 1/s timestamp writer |
| `verify-clone.sh` | checks a clone: fs, PostgreSQL recovery, ticks vs snapshot time, amcheck, pgbench invariant |
| `props.json` | example image properties copied from the source image |

Config on the VM: `/etc/disk2glance/openrc` (OS_* variables, mode 600) and
`/etc/disk2glance/props.json`. Credentials are never stored in this repo.

## Test results (VK Cloud, 20 GB ceph-hdd boot volume, pgbench -R 40 running)

| OS | Kernel | Upload | Clone | Result |
|---|---|---|---|---|
| Ubuntu 24.04 | 6.8.0-134 | 222 s, 92 MiB/s | boots, PG redo OK | ticks file = DB, amcheck OK |
| RED OS 8.0.3 | 6.12.21-1.red80 | 222 s, 92 MiB/s | boots, PG redo OK | ticks file = DB, amcheck OK |
| RED OS 7.3.7 | 6.1.175-1.el7.3 | 319 s, 64 MiB/s* | boots, PG redo OK | DB one tick behind file (expected), amcheck OK |

\* two uploads ran in parallel.

## Gotchas

- Build dattobd **as root**: genconfig resolves unexported kernel symbols from
  `/boot/System.map`, which is root-only on RHEL-likes (as a user → `modpost: "__get_unmapped_area" undefined` on 6.12).
- `sudo` secure_path drops `/usr/local/sbin` on RHEL-likes — the agent sets PATH itself.
- Never put loop/overlay files on the filesystem being snapshotted.
- VK Glance: no multihash (md5 only), import methods `glance-direct`/`copy-image` only, one upload stream per image.

## TODO

Astra Linux 1.7.5 / 1.8.6, CentOS 7, Windows 10 (VSS + vTPM handling), installable build (`install.sh`).
