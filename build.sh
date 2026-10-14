#!/bin/bash
# Baut Koe.app nach build/. Kein Xcode-Projekt, nur swiftc (wie Komorebi).
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
AIOS_DIR="$(cd "$APP_DIR/../.." && pwd)"
BUNDLE="$APP_DIR/build/Koe.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/ui" "$BUNDLE/Contents/Resources/helfer"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/koe-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/koe-swift-cache"

xcrun swiftc -O -swift-version 5 -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -target arm64-apple-macos14.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework CoreMedia -framework UniformTypeIdentifiers \
  "$APP_DIR/src/Speicher.swift" "$APP_DIR/src/Text.swift" "$APP_DIR/src/Dienste.swift" \
  "$APP_DIR/src/Audio.swift" "$APP_DIR/src/Taste.swift" "$APP_DIR/src/Pille.swift" \
  "$APP_DIR/src/Transkription.swift" "$APP_DIR/src/Fenster.swift" "$APP_DIR/src/main.swift" \
  -o "$BUNDLE/Contents/MacOS/Koe"

cp "$APP_DIR/ui/index.html" "$APP_DIR/ui/style.css" "$APP_DIR/ui/app.js" "$BUNDLE/Contents/Resources/ui/"
if [ -f "$APP_DIR/helfer/sprecher.py" ]; then cp "$APP_DIR/helfer/sprecher.py" "$BUNDLE/Contents/Resources/helfer/"; fi
printf '%s\n' "$AIOS_DIR" > "$BUNDLE/Contents/Resources/aios-root.txt"

# App-Symbol
if [ ! -f "$APP_DIR/build/icon.png" ] || [ "$APP_DIR/src/Icon.swift" -nt "$APP_DIR/build/icon.png" ]; then
  xcrun swiftc -module-cache-path "$SWIFT_MODULECACHE_PATH" -framework Cocoa "$APP_DIR/src/Icon.swift" -o "$APP_DIR/build/make-icon"
  "$APP_DIR/build/make-icon" "$APP_DIR/build/icon.png"
fi
mkdir -p "$APP_DIR/build/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP_DIR/build/icon.png" --out "$APP_DIR/build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$APP_DIR/build/icon.png" --out "$APP_DIR/build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$APP_DIR/build/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Koe</string>
<key>CFBundleIdentifier</key><string>de.kenzoweiss.koe</string>
<key>CFBundleName</key><string>Koe</string>
<key>CFBundleDisplayName</key><string>Koe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Koe nimmt deine Stimme für Diktate und Meetings auf. Die Aufnahme bleibt auf diesem Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>Koe schneidet bei Meetings den Ton vom Mac mit (Zoom, Teams, Meet). Das Bild wird nicht aufgenommen.</string>
</dict></plist>
PLIST

# Mit dem Entwickler-Zertifikat signieren, damit macOS die Rechte (Mikrofon, Bedienungshilfen) über Neubauten hinweg behält.
IDENTITAET="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITAET" ]; then
  codesign --force --sign "$IDENTITAET" "$BUNDLE"
else
  codesign --force --sign - "$BUNDLE"
  echo "Hinweis: ohne Entwickler-Zertifikat signiert, Rechte müssen nach jedem Neubau neu erteilt werden."
fi
printf 'Fertig: %s\n' "$BUNDLE"
