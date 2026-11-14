#!/bin/bash
# Offline check: JVM unit tests and a debug APK. No device or account access.
set -euo pipefail
cd "$(dirname "$0")/../android"
./gradlew --console=plain :app:testDebugUnitTest :native-bridge:testDebugUnitTest :app:assembleDebug
unzip -l app/build/outputs/apk/debug/app-debug.apk | grep -F 'assets/notices/samsung-re-health-LICENSE.txt' >/dev/null
echo "Android unit tests and debug build passed."
