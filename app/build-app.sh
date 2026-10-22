#!/bin/bash
# Builds Jancast.app into ../build/Jancast.app
#   ./build-app.sh            release build + bundle + ad-hoc signature
# Run the result:  open ../build/Jancast.app            (real backend)
#                  open ../build/Jancast.app --args --mock   (simulated data)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
OUT="$ROOT/build/Jancast.app"
ICON_CACHE="$APP_DIR/.build/icon"

cd "$APP_DIR"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Jancast"

# Fresh bundle skeleton (only ever touches build/Jancast.app).
if [ -d "$OUT" ]; then rm -r "$OUT"; fi
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Jancast"

# App icon: Resources/AppIcon.png (1024 px artwork, already in the icon shape),
# else rendered by scripts/make-icon.swift. Rebuilt when the source changes.
# Nice-to-have: skipped silently if it fails.
ICON_KEY=""
ICON_SRC="$APP_DIR/Resources/AppIcon.png"
ICON_SUM="$( (cat "$ICON_SRC" 2>/dev/null || cat "$APP_DIR/scripts/make-icon.swift") | shasum | cut -c1-12)"
if [ "$(cat "$ICON_CACHE/source" 2>/dev/null)" != "$ICON_SUM" ]; then
  rm -f "$ICON_CACHE/Jancast.icns"
fi
if [ ! -f "$ICON_CACHE/Jancast.icns" ]; then
  mkdir -p "$ICON_CACHE/Jancast.iconset"
  if { [ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$ICON_CACHE/icon_1024.png"; } ||
     swift "$APP_DIR/scripts/make-icon.swift" "$ICON_CACHE/icon_1024.png" 2>/dev/null; then
    for s in 16 32 128 256 512; do
      sips -z $s $s "$ICON_CACHE/icon_1024.png" --out "$ICON_CACHE/Jancast.iconset/icon_${s}x${s}.png" >/dev/null
      d=$((s * 2))
      sips -z $d $d "$ICON_CACHE/icon_1024.png" --out "$ICON_CACHE/Jancast.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_CACHE/Jancast.iconset" -o "$ICON_CACHE/Jancast.icns" && echo "$ICON_SUM" > "$ICON_CACHE/source" || true
  fi
fi
if [ -f "$ICON_CACHE/Jancast.icns" ]; then
  cp "$ICON_CACHE/Jancast.icns" "$OUT/Contents/Resources/Jancast.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>Jancast</string>"
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.jancast.app</string>
  <key>CFBundleName</key><string>Jancast</string>
  <key>CFBundleDisplayName</key><string>Jancast</string>
  <key>CFBundleExecutable</key><string>Jancast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  $ICON_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Jancast finds Apple TVs on your network and streams video to them.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_airplay._tcp</string>
    <string>_raop._tcp</string>
    <string>_mediaremotetv._tcp</string>
    <string>_companion-link._tcp</string>
    <string>_appletv-v2._tcp</string>
    <string>_touch-able._tcp</string>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>mkv</string><string>mp4</string><string>m4v</string><string>mov</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Extended attributes (Finder info, provenance) make codesign refuse the bundle.
xattr -cr "$OUT" 2>/dev/null || true
codesign -s - --force --deep "$OUT"
codesign --verify --verbose=1 "$OUT"
echo "Built $OUT"
