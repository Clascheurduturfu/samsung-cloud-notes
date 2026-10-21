#!/bin/bash
# Offline check: no signing setup, Keychain access or cloud requests.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/samsung-cloud-notes-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" Sources/*.swift -o "$CHECK_DIR/SamsungCloudNotes-$arch"
done
for source in credential-store import-signing-identity sign-app make-icon; do
  xcrun swiftc -swift-version 5 "scripts/$source.swift" -o "$CHECK_DIR/$source"
done
"$CHECK_DIR/SamsungCloudNotes-$(uname -m)" --self-test
