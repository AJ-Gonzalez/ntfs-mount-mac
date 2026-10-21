#!/bin/bash
# Builds build/NTFSMount.app. Pass --install to copy it to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NTFSMount.app"
RES="$APP/Contents/Resources"

cd "$ROOT"

if [[ ! -x "$ROOT/build/ntfs-3g" ]]; then
    "$ROOT/scripts/build-ntfs3g.sh"
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$ROOT/.build/release/NTFSMount" "$APP/Contents/MacOS/NTFSMount"
cp "$ROOT/.build/release/ntfsmount-helper" "$RES/ntfsmount-helper"
cp "$ROOT/build/ntfs-3g" "$RES/ntfs-3g"
cp "$ROOT/scripts/install-helper.sh" "$RES/install-helper.sh"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

chmod +x "$APP/Contents/MacOS/NTFSMount" "$RES/ntfsmount-helper" "$RES/ntfs-3g" "$RES/install-helper.sh"
codesign --force --sign - "$RES/ntfsmount-helper" >/dev/null 2>&1 || true
codesign --force --sign - "$RES/ntfs-3g" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/NTFSMount.app"
    ditto "$APP" "/Applications/NTFSMount.app"
    echo "Installed /Applications/NTFSMount.app"
fi
