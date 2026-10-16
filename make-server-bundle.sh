#!/bin/bash
# Build dist/d2g-server-<ver>.tar.gz: orchestrator/receiver code plus the agent bundle the
# orchestrator hands out to source VMs.
set -euo pipefail
cd "$(dirname "$0")"
VER=$(cat VERSION)
./make-bundle.sh >/dev/null
OUT=dist/d2g-server-$VER
rm -rf "$OUT" && mkdir -p "$OUT/pkg"
cp -r server/d2g server/install.sh server/unique-boot.sh server/d2g-orch.service server/d2g-rx.service VERSION "$OUT/"
find "$OUT" -name __pycache__ -prune -exec rm -rf {} +
cp "dist/disk2glance-$VER.tar.gz" "$OUT/pkg/"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "dist/d2g-server-$VER.tar.gz" -C dist "d2g-server-$VER"
(cd dist && { sha256sum "d2g-server-$VER.tar.gz" 2>/dev/null || shasum -a 256 "d2g-server-$VER.tar.gz"; } >"d2g-server-$VER.tar.gz.sha256")
echo "dist/d2g-server-$VER.tar.gz  $(du -h "dist/d2g-server-$VER.tar.gz" | cut -f1)"
