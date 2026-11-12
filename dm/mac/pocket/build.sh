#!/bin/bash
# Builds NX Pocket for Mac (project.yml) into <output>/NX Pocket.app. Usage: dm/mac/pocket/build.sh <output dir> [bundle ID]
# The app is signed ad hoc; it runs this checkout's scripts, so it stays beside it (AppModel.findRepo finds the checkout from the app's place, else Setup asks).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:?usage: build.sh <output dir> [bundle ID]}
export DM_MAC_BUNDLE_ID=${2:-org.nxnative.pocket.mac}
export DM_MAC_UPDATE_KEY=${DM_MAC_UPDATE_KEY:-$(cat update-key.pub 2>/dev/null || true)}   # the releases' Ed25519 public key (release.py keygen): the updater installs only what it signed
lock() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' tools/tools.lock 2>/dev/null; }   # the tool kit Setup downloads (tools/make_tools.py)
export DM_MAC_TOOLS_VERSION=$(lock version) DM_MAC_TOOLS_URL=${DM_MAC_TOOLS_URL:-$(lock url)} DM_MAC_TOOLS_SHA256=$(lock sha256) DM_MAC_TOOLS_SIZE=$(lock size) DM_MAC_TOOLS_PARTS=${DM_MAC_TOOLS_PARTS-$(lock parts)}   # DM_MAC_TOOLS_URL: a test build reads the kit from another place (file://)
export DM_MAC_BUILD=${DM_MAC_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)} DM_MAC_COMMIT=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)   # About shows them
xcodegen generate --spec project.yml --quiet
ROOT=$(cd ../../.. && pwd)   # the checkout's path, mapped to "." in the binary (assertion and #file strings), so a released app names no folder of the machine that built it
xcodebuild -project NXPocketMac.xcodeproj -scheme NXPocketMac -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$OUT/dd" -quiet build \
    "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $ROOT=." "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=."
rm -rf "$OUT/NX Pocket.app"; ditto "$OUT/dd/Build/Products/Release/NX Pocket.app" "$OUT/NX Pocket.app"
# the debug map's object paths (N_OSO, in the build folder) out too, then the ad hoc signature again over the stripped binary
strip -S -x "$OUT/NX Pocket.app/Contents/MacOS/NX Pocket" 2>/dev/null
codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$OUT/NX Pocket.app"
echo "app: $OUT/NX Pocket.app"
