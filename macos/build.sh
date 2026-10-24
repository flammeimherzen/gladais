#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
cd "$SRC"
swift build -c release
APP="$ROOT/Gladais.app"
rm -rf "$APP" "$ROOT/Glaze.app"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Glaze" "$APP/Contents/MacOS/Glaze"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
