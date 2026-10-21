#!/bin/bash
# Offline check: builds the iOS app for the simulator and runs the shared
# self-tests inside a simulator. No signing, Keychain or account access.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/samsung-cloud-notes-ios.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
xcodebuild -quiet -project iOS/SamsungCloudNotes.xcodeproj -scheme SamsungCloudNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$CHECK_DIR" CODE_SIGNING_ALLOWED=NO build
APP="$CHECK_DIR/Build/Products/Debug-iphonesimulator/SamsungCloudNotes.app"
test -f "$APP/Notices/samsung-re-health-LICENSE.txt"
DEVICE=$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for r in d for x in d[r] if x["name"].startswith("iPhone")))')
if xcrun simctl list devices booted | grep -q "$DEVICE"; then BOOTED=0; else BOOTED=1; xcrun simctl boot "$DEVICE"; fi
trap 'rm -rf "$CHECK_DIR"; if [ "$BOOTED" = 1 ]; then xcrun simctl shutdown "$DEVICE"; fi' EXIT
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
# The app writes its verdict to its own tmp directory; remove any earlier one first.
RESULT="$(xcrun simctl get_app_container "$DEVICE" local.samsung-cloud-notes data)/tmp/self-test-result.txt"
rm -f "$RESULT"
xcrun simctl launch --terminate-running-process "$DEVICE" local.samsung-cloud-notes --self-test >/dev/null
for _ in $(seq 1 120); do [ -s "$RESULT" ] && break; sleep 1; done
[ -s "$RESULT" ] || { echo "The self-test produced no result within 120 seconds." >&2; exit 1; }
cat "$RESULT"
grep -qx "Offline self-tests passed." "$RESULT"
echo "iOS offline self-tests passed."
