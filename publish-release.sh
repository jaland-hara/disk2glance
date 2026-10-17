#!/bin/bash
# Publish a GitHub Release: dist/disk2glance-<ver>.tar.gz (+ .sha256, install.sh) — the agent bundle,
# dist/d2g-server-<ver>.tar.gz (+ .sha256) and d2g-server-install.sh — the orchestrator.
# Needs a fine-grained token with "Contents: Read and write" on this repo in $GITHUB_TOKEN.
# The token is only read from the environment, never stored.
#   GITHUB_TOKEN=... ./publish-release.sh
set -euo pipefail
cd "$(dirname "$0")"
REPO=${REPO:-jaland-hara/disk2glance}
VER=$(cat VERSION); TAG=v$VER
B=dist/disk2glance-$VER.tar.gz
SB=dist/d2g-server-$VER.tar.gz
[ -n "${GITHUB_TOKEN:-}" ] || { echo "set GITHUB_TOKEN"; exit 1; }
[ -f "$B" ] && [ -f "$B.sha256" ] && [ -f dist/install.sh ] || { echo "run ./make-bundle.sh first"; exit 1; }
[ -f "$SB" ] && [ -f "$SB.sha256" ] || { echo "run ./make-server-bundle.sh first"; exit 1; }
(cd dist && shasum -a 256 -c "disk2glance-$VER.tar.gz.sha256" >/dev/null && shasum -a 256 -c "d2g-server-$VER.tar.gz.sha256" >/dev/null) \
  || { echo "bundle checksum mismatch"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "tag $TAG missing (git tag + push first)"; exit 1; }

api() { curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

notes=$(cat "dist/RELEASE_NOTES.md" 2>/dev/null || echo "disk2glance $VER")
rel=$(api "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null || true)
if [ -z "$rel" ]; then
  rel=$(api -X POST "https://api.github.com/repos/$REPO/releases" \
    -d "$(jq -n --arg t "$TAG" --arg n "disk2glance $VER" --arg b "$notes" '{tag_name:$t,name:$n,body:$b}')")
  echo "release $TAG created"
fi
id=$(jq -r .id <<<"$rel")

for f in "$B" "$B.sha256" dist/install.sh "$SB" "$SB.sha256" d2g-server-install.sh; do
  name=$(basename "$f")
  old=$(jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .id' <<<"$rel")
  [ -n "$old" ] && api -X DELETE "https://api.github.com/repos/$REPO/releases/assets/$old" >/dev/null
  api -X POST -H "Content-Type: application/octet-stream" --data-binary @"$f" \
    "https://uploads.github.com/repos/$REPO/releases/$id/assets?name=$name" | jq -r '"uploaded " + .name + " (" + (.size|tostring) + " B)"'
done
echo "https://github.com/$REPO/releases/tag/$TAG"
