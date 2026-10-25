#!/bin/bash
# Builds the downloadable Jancast: a self-contained Jancast.app with its own
# Python (+ pyatv), ffmpeg/ffprobe and OCR helper inside, and a disk image:
#   ./package-app.sh              → ../build/Jancast-<version>.dmg, and for the
#                                   updater Jancast-<version>.zip + latest.json
# (and ../build/package/Jancast.app; ../build/Jancast.app stays the dev build).
# Apple Silicon only. Downloads and the ffmpeg build are cached in .build/dist.
# The app is ad-hoc signed (no Developer ID), so Gatekeeper asks once.
set -euo pipefail

VERSION="${VERSION:-1.1}"
PY_VERSION=3.14.9
PY_RELEASE=20261021
PY_SHA256=226d696642a8a53d03b4d5b255b1c319b1575a6d44bd723a953c9f507755e36a
FFMPEG_VERSION=8.1.2

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
DIST="$APP_DIR/.build/dist"
APP="$ROOT/build/package/Jancast.app"
RES="$APP/Contents/Resources"
mkdir -p "$DIST/dl"

[ "$(uname -m)" = arm64 ] || { echo "package-app.sh builds for Apple Silicon (arm64) only" >&2; exit 1; }

# ---- ffmpeg: LGPL, only built-in codecs plus VideoToolbox/AudioToolbox, ----
# ---- statically linked so it needs nothing outside macOS.               ----
FF="$DIST/ffmpeg-$FFMPEG_VERSION"
if [ ! -x "$FF/bin/ffmpeg" ] || [ ! -x "$FF/bin/ffprobe" ]; then
  TAR="$DIST/dl/ffmpeg-$FFMPEG_VERSION.tar.xz"
  [ -f "$TAR" ] || curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TAR"
  SRC="$DIST/src/ffmpeg-$FFMPEG_VERSION"
  rm -rf "$SRC"; mkdir -p "$DIST/src"
  tar -xJf "$TAR" -C "$DIST/src"
  (
    cd "$SRC"
    ./configure --prefix="$FF" --arch=arm64 --cc=clang \
      --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
      --disable-autodetect --enable-videotoolbox --enable-audiotoolbox \
      --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv \
      --disable-shared --enable-static --disable-doc --disable-ffplay --disable-debug
    make -j"$(sysctl -n hw.ncpu)"
    make install
    cp COPYING.LGPLv2.1 "$FF/"
  ) > "$DIST/ffmpeg-build.log" 2>&1 || { tail -30 "$DIST/ffmpeg-build.log"; exit 1; }
fi

# ---- The app itself ----
VERSION="$VERSION" bash "$APP_DIR/build-app.sh"
rm -rf "$APP"; mkdir -p "$(dirname "$APP")"
ditto "$ROOT/build/Jancast.app" "$APP"

# ---- Python (python-build-standalone: relocatable, no system Python needed) ----
PY_TAR="$DIST/dl/cpython-$PY_VERSION+$PY_RELEASE-aarch64-apple-darwin-install_only.tar.gz"
[ -f "$PY_TAR" ] || curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/$(basename "$PY_TAR")" -o "$PY_TAR"
echo "$PY_SHA256  $PY_TAR" | shasum -a 256 -c - >/dev/null
tar -xzf "$PY_TAR" -C "$RES"                     # → Resources/python
PY="$RES/python/bin/python3"
"$PY" -m pip install --quiet --disable-pip-version-check --no-cache-dir -r "$ROOT/requirements.txt"
"$PY" -m pip uninstall --quiet -y pip
rm -rf "$RES/python/lib/python3."*/test "$RES/python/lib/python3."*/idlelib "$RES/python/lib/python3."*/tkinter \
       "$RES/python/lib/tcl"* "$RES/python/lib/tk"* "$RES/python/lib/itcl"* "$RES/python/lib/thread"* \
       "$RES/python/share" "$RES/python/include"
# Activity Monitor shows the backend as "Jancast Backend".
cp "$(cd "$RES/python/bin" && pwd -P)/$(readlink "$PY" || basename "$PY")" "$RES/python/bin/Jancast Backend"

# ---- The backend, ffmpeg and the OCR helper ----
mkdir -p "$RES/backend" "$RES/bin"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$ROOT/jancast" "$RES/backend/"
cp "$FF/bin/ffmpeg" "$FF/bin/ffprobe" "$RES/bin/"
swiftc -O -target arm64-apple-macos14.0 -o "$RES/bin/jancast-ocr" "$ROOT/jancast/ocr_helper.swift"
# Licences: ours, the notices, and the LGPL that covers the bundled ffmpeg.
mkdir -p "$RES/licenses"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$RES/licenses/"
cp "$FF/COPYING.LGPLv2.1" "$RES/licenses/FFmpeg-COPYING.LGPLv2.1"
# Byte-compile now: the signed bundle must not change when it runs.
"$PY" -m compileall -q -j0 "$RES/backend" "$RES/python/lib" >/dev/null || true

# ---- Sign (ad hoc): every binary inside, then the bundle ----
xattr -cr "$APP"
find "$RES" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q Mach-O; then codesign -s - --force "$f" 2>/dev/null; fi
  done
codesign -s - --force "$APP"
codesign --verify --deep --strict "$APP"

# ---- Disk image: the app, a link to Applications and a background that says
# what to do (drag, then "Open Anyway" the first time). dmgbuild lays out the
# Finder window without scripting Finder.
# 1.6.6+ (Python 3.10+, so on the Python downloaded above): with older ones
# macOS 26 Finder showed no background.
DMGBUILD="$DIST/dmgbuild-1.6.7/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
  mkdir -p "$DIST/tools-python"
  tar -xzf "$PY_TAR" -C "$DIST/tools-python"
  "$DIST/tools-python/python/bin/python3" -m venv "$DIST/dmgbuild-1.6.7"
  "$DIST/dmgbuild-1.6.7/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.7
fi
BG="$DIST/dmg-background"
mkdir -p "$BG"
swift "$APP_DIR/scripts/make-dmg-background.swift" "$BG/bg.png" 1
swift "$APP_DIR/scripts/make-dmg-background.swift" "$BG/bg@2x.png" 2
tiffutil -cathidpicheck "$BG/bg.png" "$BG/bg@2x.png" -out "$BG/background.tiff" 2>/dev/null
DMG="$ROOT/build/Jancast-$VERSION.dmg"
rm -f "$DMG"
# A mounted image with the same name makes dmgbuild's copy "Jancast 1.1 1",
# and the window's link to its background then points there (no background).
if [ -d "/Volumes/Jancast $VERSION" ]; then
  echo "Eject the mounted \"Jancast $VERSION\" disk image first." >&2
  exit 1
fi
"$DMGBUILD" -s "$APP_DIR/scripts/dmg-settings.py" -D app="$APP" -D background="$BG/background.tiff" \
  "Jancast $VERSION" "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"

# ---- Updater: the app as a zip, and latest.json describing it ----
# Upload all three to the release; the app reads
# releases/latest/download/latest.json (Updater.swift).
ZIP="$ROOT/build/Jancast-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
REPO_URL="https://github.com/jananderssonnortan/jancast/releases/download/v$VERSION"
cat > "$ROOT/build/latest.json" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "${UPDATE_URL:-$REPO_URL/Jancast-$VERSION.zip}",
  "sha256": "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
}
JSON
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1)) and latest.json (build $BUILD)"
