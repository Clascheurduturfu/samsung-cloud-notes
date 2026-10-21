#!/bin/bash
# Builds the release APK into dist/. The signing key lives outside the repository
# (default ~/.android/samsung-cloud-notes-release.jks) and its password in the
# login Keychain; both are created on first use. Keep that keystore: every later
# release must be signed with it for in-place updates to work.
set -euo pipefail
cd "$(dirname "$0")/.."
KEYSTORE="${SCN_ANDROID_KEYSTORE:-$HOME/.android/samsung-cloud-notes-release.jks}"
SERVICE="local.samsung-cloud-notes.android-release-key"
if ! PASSWORD=$(security find-generic-password -s "$SERVICE" -a release -w 2>/dev/null); then
  [ -e "$KEYSTORE" ] && { echo "Keystore exists but its Keychain password ($SERVICE) is missing." >&2; exit 1; }
  PASSWORD=$(openssl rand -base64 30 | tr -d '/+=\n')
  security add-generic-password -s "$SERVICE" -a release -w "$PASSWORD" -l "Samsung Cloud Notes Android release key"
fi
if [ ! -e "$KEYSTORE" ]; then
  mkdir -p "$(dirname "$KEYSTORE")"
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias samsung-cloud-notes -keyalg RSA -keysize 4096 -validity 10000 \
    -dname "CN=Samsung Cloud Notes (unofficial)" -storepass "$PASSWORD" -keypass "$PASSWORD" >/dev/null
  chmod 600 "$KEYSTORE"
  echo "Created release keystore $KEYSTORE. Back it up privately."
fi
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Shared/Cloud.swift)
(cd android && SCN_ANDROID_KEYSTORE="$KEYSTORE" SCN_ANDROID_KEYSTORE_PASSWORD="$PASSWORD" ./gradlew --console=plain -q :app:assembleRelease)
mkdir -p dist
cp android/app/build/outputs/apk/release/app-release.apk "dist/SamsungCloudNotes-$VERSION-Android.apk"
echo "dist/SamsungCloudNotes-$VERSION-Android.apk"
