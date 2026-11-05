#!/bin/bash
# Builds Luftbro.app into ../build/Luftbro.app
#   ./build-app.sh            release build + bundle + ad-hoc signature
# (package-app.sh builds the self-contained, downloadable version on top of this.)
# Run the result:  open ../build/Luftbro.app            (real backend)
#                  open ../build/Luftbro.app --args --mock   (simulated data)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
OUT="${OUT:-$ROOT/build/Luftbro.app}"     # package-app.sh builds elsewhere
ICON_CACHE="$APP_DIR/.build/icon"
VERSION="${VERSION:-1.0}"
# Always increasing, also when VERSION stays the same: the updater compares it.
BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"

cd "$APP_DIR"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Luftbro"

# Fresh bundle skeleton (only ever touches build/Luftbro.app).
if [ -d "$OUT" ]; then rm -r "$OUT"; fi
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Luftbro"

# App icon: Resources/AppIcon.png (1024 px artwork, already in the icon shape,
# made by `swift scripts/make-icon.swift Resources/AppIcon.png`), else rendered
# by that script here. Rebuilt when the source changes.
# Nice-to-have: skipped silently if it fails.
ICON_KEY=""
ICON_SRC="$APP_DIR/Resources/AppIcon.png"
ICON_SUM="$( (cat "$ICON_SRC" 2>/dev/null || cat "$APP_DIR/scripts/make-icon.swift") | shasum | cut -c1-12)"
if [ "$(cat "$ICON_CACHE/source" 2>/dev/null)" != "$ICON_SUM" ]; then
  rm -f "$ICON_CACHE/Luftbro.icns"
fi
if [ ! -f "$ICON_CACHE/Luftbro.icns" ]; then
  mkdir -p "$ICON_CACHE/Luftbro.iconset"
  if { [ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$ICON_CACHE/icon_1024.png"; } ||
     swift "$APP_DIR/scripts/make-icon.swift" "$ICON_CACHE/icon_1024.png" 2>/dev/null; then
    for s in 16 32 128 256 512; do
      sips -z $s $s "$ICON_CACHE/icon_1024.png" --out "$ICON_CACHE/Luftbro.iconset/icon_${s}x${s}.png" >/dev/null
      d=$((s * 2))
      sips -z $d $d "$ICON_CACHE/icon_1024.png" --out "$ICON_CACHE/Luftbro.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_CACHE/Luftbro.iconset" -o "$ICON_CACHE/Luftbro.icns" && echo "$ICON_SUM" > "$ICON_CACHE/source" || true
  fi
fi
if [ -f "$ICON_CACHE/Luftbro.icns" ]; then
  cp "$ICON_CACHE/Luftbro.icns" "$OUT/Contents/Resources/Luftbro.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>Luftbro</string>"
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.luftbro.app</string>
  <key>CFBundleName</key><string>Luftbro</string>
  <key>CFBundleDisplayName</key><string>Luftbro</string>
  <key>CFBundleExecutable</key><string>Luftbro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  $ICON_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Luftbro finds Apple TVs on your network and streams video to them.</string>
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
      <key>CFBundleTypeExtensions</key><array><string>mkv</string><string>mp4</string><string>m4v</string><string>mov</string><string>avi</string><string>ts</string><string>m2ts</string><string>webm</string><string>mpg</string><string>mpeg</string><string>vob</string><string>mts</string><string>m2t</string><string>wmv</string><string>asf</string><string>flv</string><string>ogv</string><string>ogm</string><string>3gp</string><string>dv</string><string>rm</string><string>rmvb</string><string>divx</string><string>part</string></array>
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
