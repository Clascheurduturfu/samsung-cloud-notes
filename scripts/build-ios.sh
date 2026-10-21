#!/bin/bash
# Builds an unsigned iOS IPA into dist/ for sideloading tools (AltStore,
# Sideloadly…), which sign it with the installer's own Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Shared/Cloud.swift)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/samsung-cloud-notes-ipa.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
xcodebuild -quiet -project iOS/SamsungCloudNotes.xcodeproj -scheme SamsungCloudNotes -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_DIR/dd" CODE_SIGNING_ALLOWED=NO build
mkdir -p "$BUILD_DIR/Payload" dist
cp -R "$BUILD_DIR/dd/Build/Products/Release-iphoneos/SamsungCloudNotes.app" "$BUILD_DIR/Payload/"
rm -f "dist/SamsungCloudNotes-$VERSION-iOS-unsigned.ipa"
(cd "$BUILD_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload "$OLDPWD/dist/SamsungCloudNotes-$VERSION-iOS-unsigned.ipa")
echo "dist/SamsungCloudNotes-$VERSION-iOS-unsigned.ipa"
