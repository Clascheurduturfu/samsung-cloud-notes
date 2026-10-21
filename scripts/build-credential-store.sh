#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HELPER="$1"
INSTALLED="/Applications/Samsung Cloud Notes.app/Contents/Resources/CredentialStore.app"
if [ -x "$HELPER/Contents/MacOS/CredentialStore" ]; then codesign --verify --strict "$HELPER"; exit 0; fi
mkdir -p "$(dirname "$HELPER")"
if [ -x "$INSTALLED/Contents/MacOS/CredentialStore" ]; then
  ditto "$INSTALLED" "$HELPER"
  codesign --verify --strict "$HELPER"
  exit 0
fi
mkdir -p "$HELPER/Contents/MacOS" dist/build
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 scripts/credential-store.swift -o dist/build/CredentialStore-arm64
if [ "${BUILD_UNIVERSAL:-1}" = 1 ]; then
  xcrun swiftc -swift-version 5 -O -target x86_64-apple-macosx13.0 scripts/credential-store.swift -o dist/build/CredentialStore-x86_64
  lipo -create dist/build/CredentialStore-arm64 dist/build/CredentialStore-x86_64 -output "$HELPER/Contents/MacOS/CredentialStore"
else
  cp dist/build/CredentialStore-arm64 "$HELPER/Contents/MacOS/CredentialStore"
fi
cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>CredentialStore</string><key>CFBundleIdentifier</key><string>local.samsung-cloud-notes.credentials</string><key>CFBundleName</key><string>Samsung Cloud Notes Credential Store</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
bash scripts/sign-macos.sh "$HELPER"
