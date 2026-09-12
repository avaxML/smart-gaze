#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP="dist/SmartGaze.app"

swift build -c release --product SmartGaze
BIN_PATH="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/SmartGaze" "$APP/Contents/MacOS/SmartGaze"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.avaxml.smartgaze</string>
	<key>CFBundleName</key>
	<string>SmartGaze</string>
	<key>CFBundleExecutable</key>
	<string>SmartGaze</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSCameraUsageDescription</key>
	<string>SmartGaze uses the webcam to track where you are looking on screen, so it can explain whatever your eyes settle on.</string>
</dict>
</plist>
PLIST

# Fetched models ride inside the bundle so a plain `open` works from anywhere.
# They are gitignored and never committed; this only copies what a fetch script
# already placed in Models/.
if [ -d "$REPO_ROOT/Models" ]; then
  mkdir -p "$APP/Contents/Resources/Models"
  for model in blazegaze.mlmodelc face-mesh/face_mesh.mlmodelc iris/iris_landmark_64x64_float32.mlmodelc; do
    if [ -d "$REPO_ROOT/Models/$model" ]; then
      mkdir -p "$APP/Contents/Resources/Models/$(dirname "$model")"
      cp -R "$REPO_ROOT/Models/$model" "$APP/Contents/Resources/Models/$model"
    fi
  done
fi

plutil -lint "$APP/Contents/Info.plist" > /dev/null

# TCC identifies an ad-hoc signed app by its cdhash, which changes on every
# build, so Screen Recording and Camera grants would be lost each rebuild. A
# local self-signed identity (see make-signing-identity.sh) gives a designated
# requirement that survives rebuilds.
SIGN_IDENTITY="${SMART_GAZE_SIGN_IDENTITY:-SmartGaze Local Development}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
else
  echo "note: no '$SIGN_IDENTITY' identity found, signing ad-hoc; TCC grants will not survive rebuilds" >&2
  codesign --force --sign - --timestamp=none "$APP"
fi

echo "$REPO_ROOT/$APP"
