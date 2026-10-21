#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Samsung Cloud Notes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p dist/build
if [ ! -s "$HOME/Library/Application Support/SamsungCloudNotes/SigningIdentity.txt" ] && [ -z "${SIGNING_IDENTITY:-}" ]; then bash scripts/setup-local-signing.sh; fi
bash scripts/build-credential-store.sh "$APP/Contents/Resources/CredentialStore.app"
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Cloud.swift | tr -d '\r')
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.0 Sources/*.swift -o dist/build/SamsungCloudNotes-arm64
if [ "${BUILD_UNIVERSAL:-1}" = "1" ]; then
  xcrun swiftc -swift-version 5 -parse-as-library -O -target x86_64-apple-macosx13.0 Sources/*.swift -o dist/build/SamsungCloudNotes-x86_64
  xcrun lipo -create dist/build/SamsungCloudNotes-arm64 dist/build/SamsungCloudNotes-x86_64 -output "$APP/Contents/MacOS/SamsungCloudNotes"
else
  cp dist/build/SamsungCloudNotes-arm64 "$APP/Contents/MacOS/SamsungCloudNotes"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SamsungCloudNotes</string>
<key>CFBundleIdentifier</key><string>local.samsung-cloud-notes</string>
<key>CFBundleName</key><string>Samsung Cloud Notes</string>
<key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
<key>CFBundleVersion</key><string>1.0.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SamsungCloudNotesVersion string $VERSION" "$APP/Contents/Info.plist"
xcrun swift scripts/make-icon.swift dist/build/AppIcon.iconset
iconutil -c icns dist/build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Notices"
cp LICENSE "$APP/Contents/Resources/Notices/"
cp docs/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Notices/"
cp docs/third-party/samsung-re-health-LICENSE.txt "$APP/Contents/Resources/Notices/"
bash scripts/sign-macos.sh "$APP"
"$APP/Contents/MacOS/SamsungCloudNotes" --self-test
