#!/bin/bash
# Baut Koe.app mit allem, was sie braucht (whisper.cpp, ffmpeg, uv aus werkzeuge.sh).
# Kein Xcode-Projekt, nur swiftc.
#
#   bash build.sh         baut und installiert nach /Applications (Finder: Programme)
#   bash build.sh --dmg   baut build/Koe-<Version>.dmg zum Weitergeben, installiert nichts
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DMG=0
[ "${1:-}" = "--dmg" ] && DMG=1
bash "$APP_DIR/werkzeuge.sh"
# Eine Stelle für die Version. Bei einer neuen Fassung hier hochsetzen,
# in CHANGELOG.md eine Zeile ergänzen und im koe-Repo einen Tag setzen.
VERSION="$(tr -d " \n" < "$APP_DIR/VERSION")"
BUNDLE="$APP_DIR/build/Koe.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/ui" "$BUNDLE/Contents/Resources/helfer" "$BUNDLE/Contents/Resources/bin"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/koe-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/koe-swift-cache"

xcrun swiftc -O -swift-version 5 -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -target arm64-apple-macos14.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework CoreMedia -framework UniformTypeIdentifiers \
  "$APP_DIR/src/Speicher.swift" "$APP_DIR/src/Text.swift" "$APP_DIR/src/Dienste.swift" "$APP_DIR/src/Einrichtung.swift" \
  "$APP_DIR/src/Audio.swift" "$APP_DIR/src/Taste.swift" "$APP_DIR/src/Pille.swift" \
  "$APP_DIR/src/Transkription.swift" "$APP_DIR/src/Fenster.swift" "$APP_DIR/src/main.swift" \
  -o "$BUNDLE/Contents/MacOS/Koe"

cp "$APP_DIR/ui/index.html" "$APP_DIR/ui/style.css" "$APP_DIR/ui/app.js" "$BUNDLE/Contents/Resources/ui/"
cp "$APP_DIR/helfer/sprecher.py" "$APP_DIR/helfer/requirements.txt" "$BUNDLE/Contents/Resources/helfer/"
# Mitgelieferte Programme samt Lizenzen
W="$APP_DIR/build/werkzeuge/bin"
cp "$W/whisper-server" "$W/whisper-cli" "$W/ffmpeg" "$W/uv" "$BUNDLE/Contents/Resources/bin/"
mkdir -p "$BUNDLE/Contents/Resources/Lizenzen"
cp "$W/"*-LICENSE.txt "$APP_DIR/LICENSE" "$BUNDLE/Contents/Resources/Lizenzen/"
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

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Koe</string>
<key>CFBundleIdentifier</key><string>de.kenzoweiss.koe</string>
<key>CFBundleName</key><string>Koe</string>
<key>CFBundleDisplayName</key><string>Koe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Kenzo Weiss, MIT-Lizenz</string>
<key>NSMicrophoneUsageDescription</key><string>Koe nimmt deine Stimme für Diktate und Meetings auf. Die Aufnahme bleibt auf diesem Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>Koe schneidet bei Meetings den Ton vom Mac mit (Zoom, Teams, Meet). Das Bild wird nicht aufgenommen.</string>
</dict></plist>
PLIST

# Signieren. Für die eigene Installation mit dem Entwickler-Zertifikat, damit macOS die Rechte
# (Mikrofon, Bedienungshilfen) über Neubauten hinweg behält. Die DMG bekommt nur eine Ad-hoc-Signatur:
# Das Entwickler-Zertifikat hilft auf fremden Macs nicht und trägt die E-Mail-Adresse des Kontos.
IDENTITAET="-"
if [ "$DMG" = 0 ]; then
  IDENTITAET="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
  [ -n "$IDENTITAET" ] || { IDENTITAET="-"; echo "Hinweis: ohne Entwickler-Zertifikat signiert, Rechte müssen nach jedem Neubau neu erteilt werden."; }
fi
for b in "$BUNDLE/Contents/Resources/bin/"*; do codesign --force --sign "$IDENTITAET" "$b"; done
codesign --force --sign "$IDENTITAET" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

if [ "$DMG" = 1 ]; then
  # Disk-Image mit Koe und einer Verknüpfung auf Programme: öffnen, Koe hinüberziehen, fertig.
  INHALT="$APP_DIR/build/dmg"
  ZIEL_DMG="$APP_DIR/build/Koe-$VERSION.dmg"
  rm -rf "$INHALT" "$ZIEL_DMG"
  mkdir -p "$INHALT"
  ditto "$BUNDLE" "$INHALT/Koe.app"
  ln -s /Applications "$INHALT/Programme"
  hdiutil create -volname "Koe $VERSION" -srcfolder "$INHALT" -fs HFS+ -format UDZO -ov "$ZIEL_DMG" >/dev/null
  rm -rf "$INHALT" "$BUNDLE"
  printf 'Fertig: %s (%s)\n' "$ZIEL_DMG" "$(du -h "$ZIEL_DMG" | cut -f1)"
  exit 0
fi
# Nach /Applications installieren. Nur eine Kopie behalten, sonst findet Spotlight zwei Koe.
ZIEL="/Applications/Koe.app"
if pgrep -f "$ZIEL/Contents/MacOS/Koe" >/dev/null || pgrep -f "$BUNDLE/Contents/MacOS/Koe" >/dev/null; then
  osascript -e 'tell application id "de.kenzoweiss.koe" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Koe.app/Contents/MacOS/Koe" >/dev/null || break; sleep 0.5; done
fi
rm -rf "$ZIEL"
ditto "$BUNDLE" "$ZIEL"
rm -rf "$BUNDLE"
printf 'Fertig: %s\n' "$ZIEL"
