#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="$1"
IDENTITY="${SIGNING_IDENTITY:-}"
CONFIG="$HOME/Library/Application Support/SamsungCloudNotes/SigningIdentity.txt"
if [ -z "$IDENTITY" ] && [ -s "$CONFIG" ]; then IDENTITY=$(tr -d '\r\n' < "$CONFIG"); fi
if [ -z "$IDENTITY" ]; then
  codesign --force --sign - --identifier local.samsung-cloud-notes "$TARGET"
  exit 0
fi
mkdir -p dist/build/Signer.app/Contents/MacOS
xcrun swiftc scripts/sign-app.swift -o dist/build/Signer.app/Contents/MacOS/Signer
cat > dist/build/Signer.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Signer</string>
<key>CFBundleIdentifier</key><string>local.samsung-cloud-notes.build-signer</string>
<key>CFBundleName</key><string>Samsung Cloud Notes Build Signer</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - dist/build/Signer.app
TARGET=$(cd "$(dirname "$TARGET")" && pwd -P)/$(basename "$TARGET")
RESULT="$PWD/dist/build/sign-result.txt"
rm -f "$RESULT"
if [ -n "${SSH_CONNECTION:-}" ]; then
  # LaunchServices gives Apple's codesign access to the unlocked desktop Keychain.
  open -W -n -a "$PWD/dist/build/Signer.app" --args "$IDENTITY" "$TARGET" "$RESULT" || true
  test "$(cat "$RESULT")" = 0
else
  codesign --force --sign "$IDENTITY" --timestamp=none "$TARGET"
fi
codesign --verify --strict "$TARGET"
