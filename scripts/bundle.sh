#!/bin/bash
# Builds build/Glosa.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Glosa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --show-bin-path)"
cp "$BIN/Glosa" "$APP/Contents/MacOS/Glosa"
# Resource bundles: whatever the package ships.
for bundle in "$BIN"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glosa</string>
  <key>CFBundleDisplayName</key><string>Glosa</string>
  <key>CFBundleIdentifier</key><string>ai.glosa.translator</string>
  <key>CFBundleExecutable</key><string>Glosa</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# macOS ties the Accessibility permission to the signature. An ad-hoc signature changes with every build,
# so sign with a stable identity: GLOSA_SIGN_IDENTITY, else the first Apple Development certificate.
IDENTITY="${GLOSA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)}"
if [ -z "$IDENTITY" ]; then
  echo "warning: no signing identity, using ad-hoc; Accessibility must be re-granted after every build" >&2
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
