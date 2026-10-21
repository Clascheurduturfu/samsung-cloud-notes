# iPhone, iPad and Android

New in **1.1**. Both mobile apps sign in on the device itself, register their own device identity with Samsung and keep their own cache and drafts. Nothing is shared with, or required from, the Mac app or a Galaxy device.

## Why not Samsung's Android app?

Samsung Notes is distributed for Galaxy devices; on other phones its Samsung Cloud sync is unavailable, and sideloaded copies are unsupported. Redistributing the APK would also break this project's rule of shipping no Samsung binaries. The Android client is therefore a native port of the Mac client's protocol code, not a wrapper around Samsung's app.

## iPhone and iPad

- **Requirements:** iOS 16 or newer. Xcode 16+ to build (the project uses folder-synchronized groups).
- **Install from a release:** download `SamsungCloudNotes-<version>-iOS-unsigned.ipa` and install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your own Apple ID. Apple's free provisioning expires after seven days; refreshing or reinstalling keeps the app's data.
- **Or build it:** open `iOS/SamsungCloudNotes.xcodeproj`, select the **SamsungCloudNotes** target → **Signing & Capabilities**, choose your team and, with a free Apple ID, a unique bundle identifier, then run on your device. `bash scripts/build-ios.sh` produces the unsigned IPA.
- **Code:** the app compiles `Sources/Shared` (the same protocol, cache, drawing and model code as the Mac) plus `Sources/iOS`. Foundation's XML tree is macOS-only, so `PortableXML.swift` supplies an order-preserving parser used on iOS; the Mac self-test cross-checks its output against Foundation's.
- **Sign-in:** Samsung's page opens in an `ASWebAuthenticationSession` sheet; iOS first asks to allow account.samsung.com.
- **Credentials:** the app's own Keychain items, `AfterFirstUnlockThisDeviceOnly`; they are not synced through iCloud Keychain.
- **Files:** attachments and drawing PDFs open in Quick Look. **Export original…** produces a zipped `.samsungnote` folder for the share sheet.
- **Windows import** is available, as on the Mac.

## Android

- **Requirements:** Android 8.0 (API 26) or newer, any manufacturer, and a browser that supports Custom Tabs (Chrome, Firefox, Edge, Samsung Internet…). To build: JDK 17+ and the Android SDK (Android Studio includes both).
- **Install from a release:** download `SamsungCloudNotes-<version>-Android.apk`, open it on the phone and allow installing from that source when Android asks (or `adb install`). Release APKs are signed with the project's release key, so later releases install over it; a self-built APK uses a different key and needs an uninstall first, which deletes local drafts.
- **Or build it:** `cd android && ./gradlew :app:assembleRelease` (signed with your local debug key). `bash scripts/build-android.sh` signs with a release keystore kept outside the repository (`~/.android/samsung-cloud-notes-release.jks`, password in the login Keychain), creating both on first use; back that keystore up privately.
- **Code:** a Kotlin/Jetpack Compose port in `android/app/src/main/java/local/samsungcloudnotes/`. `Cloud.kt`, `Auth.kt`, `Store.kt`, `Drawing.kt` and `Xml.kt` mirror their Swift counterparts and must change in step; `OfflineTest.kt` mirrors the Swift self-test vectors.
- **Sign-in:** Samsung's page opens in a Custom Tab. The app claims the `ms-app://s-1-15-2-…` redirect that Samsung's SDK flow returns to, so the browser hands the callback straight back. If you close the tab, sign-in is cancelled.
- **Credentials:** sealed with an AES-GCM key held in Android Keystore (non-exportable) and stored in no-backup app storage. Android backup and device transfer are disabled for all app data.
- **Files:** attachments and drawing PDFs open in another app through a temporary content URI. **Export original…** saves a zipped `.samsungnote` folder wherever you choose.
- **Not yet available on Android:** Windows connection import.

### Android sign-in notes

- The device registers with Samsung's Android profile and its real model name (`Build.MODEL`), alias *Samsung Cloud Notes for Android*.
- On a brand-new browser profile (observed on a fresh emulator), Samsung answered the first SDK sign-in with **Access denied — unusual activity** before showing the form. After visiting account.samsung.com once in that browser, the same flow showed the normal login form. This is Samsung's risk check, not an app error; retry after visiting the site.
- If Android kills the app while the browser is open, the callback cannot complete the pending sign-in; choose **Sign in with Samsung** again.

## Shared behavior and limits

Editing, conflict checks, backups, drafts, drawing previews and export behave as on the Mac (see the [README](../README.md#know-the-limits)). Locked or encrypted notes are listed but cannot be opened. Note creation and deletion are not supported.

Logging out removes this device's saved connection; cached notes and drafts stay in the app sandbox until the app is deleted.
