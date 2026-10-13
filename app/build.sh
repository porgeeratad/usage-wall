#!/bin/bash
# Build "Usage Wall.app" (menu bar app + bundled server + page) into ./build, or into the folder given as $1.
# Needs the Xcode Command Line Tools (swiftc). Universal (arm64 + x86_64) when the SDK can build both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
NAME="Usage Wall"
BUNDLE_ID="io.github.porgeeratad.usagewall"     # = agentLabel in app/UsageWall.swift
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$OUT/$NAME.app"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v swiftc >/dev/null || { echo "swiftc not found - install the Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server" "$APP/Contents/Resources/web"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>UsageWall</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

# explicit deployment target: some toolchains default it to the running OS, and LaunchServices then refuses to
# open the app on anything older (-10825)
built=()
for arch in arm64 x86_64; do
  if swiftc -O -target "$arch-apple-macos14.0" -o "$TMP/UsageWall-$arch" "$ROOT/app/UsageWall.swift" 2>"$TMP/err-$arch"; then
    built+=("$TMP/UsageWall-$arch")
  else
    echo "note: $arch build skipped ($(head -1 "$TMP/err-$arch"))" >&2
  fi
done
[ ${#built[@]} -gt 0 ] || { cat "$TMP"/err-* >&2; exit 1; }
lipo -create "${built[@]}" -output "$APP/Contents/MacOS/UsageWall"

cp "$ROOT/server/server.py" "$APP/Contents/Resources/server/"
cp "$ROOT/web/index.html" "$APP/Contents/Resources/web/"
cp -R "$ROOT/web/fonts" "$APP/Contents/Resources/web/"
cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/"

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc signing failed (the app still runs from a local build)" >&2
echo "$APP ($(lipo -archs "$APP/Contents/MacOS/UsageWall"))"
