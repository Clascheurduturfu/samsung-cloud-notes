#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="$HOME/Library/Application Support/SamsungCloudNotes/SigningIdentity.txt"
if [ -s "$CONFIG" ]; then
  printf 'A persistent local signing identity is already configured.\n'
  exit 0
fi
mkdir -p dist/build
WORK=$(mktemp -d "$PWD/dist/build/signing.XXXXXX")
chmod 700 "$WORK"
trap 'rm -f "$WORK/key.pem" "$WORK/certificate.pem" "$WORK/identity.p12" "$WORK/password" "$WORK/openssl.cnf" "$WORK/importer"; rm -rf "$WORK/Importer.app"; rmdir "$WORK"' EXIT
umask 077
cat > "$WORK/openssl.cnf" <<'CONFIGURATION'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = Samsung Cloud Notes Local Signing
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIGURATION
openssl rand -base64 32 > "$WORK/password"
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" >/dev/null 2>&1
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" -out "$WORK/identity.p12" -passout "file:$WORK/password"
mkdir -p "$WORK/Importer.app/Contents/MacOS"
xcrun swiftc -suppress-warnings scripts/import-signing-identity.swift -o "$WORK/Importer.app/Contents/MacOS/Importer"
cat > "$WORK/Importer.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Importer</string>
<key>CFBundleIdentifier</key><string>local.samsung-cloud-notes.signing-setup</string>
<key>CFBundleName</key><string>Samsung Cloud Notes Signing Setup</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$WORK/Importer.app"
open -W -n -a "$WORK/Importer.app" --args "$WORK/identity.p12" "$WORK/password" || true
test -s "$CONFIG"
printf 'Private key retained only in Keychain; temporary key files removed on exit. No certificate trust settings changed.\n'
