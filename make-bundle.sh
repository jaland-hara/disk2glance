#!/bin/bash
# Build the distributable bundle: dist/disk2glance-<ver>.tar.gz (+ .sha256)
# Contents: agent, installer, static helper binaries, prebuilt dattobd modules,
# dattobd source (GPL; also used by install.sh --build), docs, third-party notices.
set -euo pipefail
cd "$(dirname "$0")"
VER=$(cat VERSION)
DATTOBD_TAG=${DATTOBD_TAG:-v0.12.2}
NAME=disk2glance-$VER
OUT=dist/$NAME
rm -rf "$OUT" && mkdir -p "$OUT/src" dist

cp VERSION install.sh disk2glance.sh disk2s3.sh disk2rx.sh s3restore.sh "$OUT/"
cp -r bin modules docs examples THIRD_PARTY.md README.md "$OUT/"
chmod 755 "$OUT/install.sh" "$OUT/disk2glance.sh" "$OUT/disk2s3.sh" "$OUT/disk2rx.sh" "$OUT/s3restore.sh" "$OUT"/bin/*

# dattobd source of the same tag the modules were built from
if [ ! -f "dist/dattobd-$DATTOBD_TAG.tar.gz" ]; then
  curl -fsSL -o "dist/dattobd-$DATTOBD_TAG.tar.gz" "https://github.com/datto/dattobd/archive/refs/tags/$DATTOBD_TAG.tar.gz"
fi
tar xzf "dist/dattobd-$DATTOBD_TAG.tar.gz" -C "$OUT/src"
mv "$OUT/src/dattobd-${DATTOBD_TAG#v}" "$OUT/src/dattobd"

# verify every module checksum before packing
for d in "$OUT"/modules/*/; do (cd "$d" && shasum -a 256 -c dattobd.ko.sha256 >/dev/null) || { echo "bad module $d"; exit 1; }; done

COPYFILE_DISABLE=1 tar --no-xattrs -czf "dist/$NAME.tar.gz" -C dist "$NAME" 2>/dev/null || COPYFILE_DISABLE=1 tar -czf "dist/$NAME.tar.gz" -C dist "$NAME"
(cd dist && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
cp install.sh dist/install.sh
echo "dist/$NAME.tar.gz  $(du -h "dist/$NAME.tar.gz" | cut -f1)  kernels: $(ls modules | tr '\n' ' ')"
