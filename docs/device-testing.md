# Testing on real devices and releasing 1.2

What each kind of device can prove, how to reach real hardware through Firebase, and the checklist that turns `1.2.0-beta.N` into `1.2.0`.

## What needs a real device

| Client | Where it can be tested | Why |
| --- | --- | --- |
| macOS app and `scnotes` | The owner's Mac only | Firebase has no macOS devices. CI compiles and runs offline self-tests, but sign-in, Keychain and upload need the real Mac. |
| iPhone / iPad | Firebase Test Lab (iOS physical devices, XCUITest) or a local device | Sideloaded builds; Test Lab needs an `.xctestrun` bundle built on the Mac. |
| Standalone Android app | Firebase Test Lab or Android Device Streaming | Compose UI, Keystore, browser sign-in across vendors. |
| Native Samsung Notes port | Android Device Streaming (Samsung Galaxy partner lab), then the owner's Galaxy Tab | Still untested on physical hardware. Needs an interactive Samsung login. |
| Formatting round-trip | Mac + Windows Samsung Notes + Galaxy Tab | The real check is native **downsync**: edit on one client, open on Samsung's own app, compare. |

Samsung sign-in requires the account password and verification codes. Never put them in a Test Lab Robo script or any file in this repository. Use **interactive** Device Streaming sessions and sign in yourself, ideally with a dedicated test Samsung account rather than your main one. Devices are wiped after each session, but treat any streamed device as shared hardware.

## One-time Firebase setup

1. In the [Firebase console](https://console.firebase.google.com/), create a project (for example `scn-device-tests`). No Firebase SDK is added to the apps.
2. Authenticate the CLI and select the project:

   ```sh
   gcloud auth login
   gcloud config set project scn-device-tests
   gcloud services enable testing.googleapis.com toolresults.googleapis.com
   ```

3. **Spark (free)** includes a small daily number of physical-device runs. **Blaze** includes a daily no-cost allowance, then bills per physical-device hour. Check the [current Test Lab quotas and pricing](https://firebase.google.com/docs/test-lab/usage-quotas-pricing) before enabling Blaze, and set a budget alert.

## Interactive testing on real Samsung phones (Device Streaming)

Best for the native port and for manual formatting checks.

1. Android Studio → **View → Tool Windows → Device Manager → Firebase** (Device Streaming); sign in with the Google account that owns the project and pick the project.
2. Choose a Samsung Galaxy device from the partner lab (a project Owner may need to enable the Samsung lab once).
3. Install the build: drag `android/app/build/outputs/apk/debug/app-debug.apk` (or your locally built native-port APK) onto the streamed device, or use **Run** in Android Studio.
4. Sign in with Samsung inside the stream, open the formatted test note, check the formatted view and edit text, then save.
5. On Windows Samsung Notes or the Galaxy Tab, sync and confirm the note still shows the same formatting.

Device Streaming has a free monthly minute allowance; see [Android Device Streaming](https://developer.android.com/studio/run/android-device-streaming).

## Automated runs (Test Lab)

Smoke test that the app installs, launches and survives exploration without signing in:

```sh
gcloud firebase test android models list --filter="manufacturer:samsung AND form:PHYSICAL"
gcloud firebase test android run --type robo \
  --app android/app/build/outputs/apk/debug/app-debug.apk \
  --device model=MODEL_ID,version=API_LEVEL,locale=fr,orientation=portrait \
  --device model=OTHER_MODEL,version=API_LEVEL \
  --timeout 5m
```

Results (video, logcat, crashes) appear in the Firebase console under **Test Lab**. Robo cannot get past Samsung's login, so it covers launch, the welcome screen and crash-free startup, not sync.

For iOS, build the UI test bundle on the Mac, zip the `Debug-iphoneos` folder with its `.xctestrun`, then:

```sh
gcloud firebase test ios models list
gcloud firebase test ios run --test SamsungCloudNotesTests.zip --device model=MODEL_ID,version=IOS_VERSION
```

## Release checklist for 1.2

1. **beta.1, offline gates:** CI green on `macos`, `ios`, `android`, `windows` (Swift self-tests include the rich-text suite). Build the universal Mac app with `bash scripts/build-macos.sh` once the Mac is online and confirm the version reads `1.2.0-beta.1`.
2. **Capture the real bullet format:** on the Mac, `scnotes show "Mac sync verification" --styles` prints style keys/values/offsets without note text. Record the checkbox, numbered and bullet values in `docs/validation.md` and pin them in `RichPreview.swift` (beta.2).
3. **Round-trip matrix:** use the formatted test note only. For each client (Mac, iOS, standalone Android):
   - change one word inside a bold or coloured run;
   - add a line after a checkbox item, and one after a numbered item;
   - delete one checklist line;
   - save, then sync on Windows Samsung Notes and the Galaxy Tab. The formatting must match, the note must not be flagged corrupted, and the edit must not appear as a conflict.
4. **Regression notes:** a plain note with no formatting still saves and syncs as in 1.1.1, and `scnotes edit NOTE --resend` still repairs a pre-1.1.1 note.
5. **Device spread:** run Robo on 3–5 physical Android models (including a Samsung) and one iPhone; run one interactive Device Streaming session on a Galaxy phone for the native port.
6. **Promote:** `1.2.0-beta.N` → `1.2.0-rc.1` once a full matrix run passes with no code changes in between, then `1.2.0`. Each published build keeps the version visible under the sidebar so you can confirm which build is installed.
