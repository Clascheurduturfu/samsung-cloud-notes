# Samsung Notes native beta builder

Builds an experimental local port from an owner-supplied Samsung Notes **4.4.48.15** APK. This directory contains original patch/build code and compatibility shims, not Samsung's application source or binaries. See [design, evidence and remaining gates](../docs/android-native-port.md).

This is a development prototype. Download-only mode is the initial setting. Enable **Two-way sync** in **Settings → Samsung Cloud** to use Samsung's native upload and revision logic. Independent sign-in, native downloads, creation, text updates, pen preservation and Mac readback have been exercised on a generic ARM64 API 37 emulator. It cannot replace Samsung Notes on a Samsung device because the original app uses Samsung's signing key. Use a dedicated generic ARM64 test device/emulator; do not uninstall an existing app or risk existing notes.

## Requirements

- Owner-provided APK with SHA-256 `484d3dd599355789508034ba90af9a35e09f81532564a992c131710632a467ce`.
- [Official Apktool 3.0.3](https://github.com/iBotPeaches/Apktool/releases/tag/v3.0.3), JAR SHA-256 `dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423`.
- Python 3.11+, Java 21, Android SDK/build-tools 37.0.0; the repository Gradle wrapper builds owned bridge code.
- A private local signing key for installation. Never commit it or its password.

## Build

```powershell
python android-samsung-port/build.py `
  --apk C:/private/SamsungNotes-original.apk `
  --apktool C:/tools/apktool_3.0.3.jar `
  --java-home "C:/Program Files/Eclipse Adoptium/jdk-21.0.10.7-hotspot" `
  --sdk C:/Users/you/AppData/Local/Android/Sdk `
  --stage C:/private/scnotes-native-build `
  --bridge `
  --keystore C:/private/native-beta.jks `
  --password-env SCNP_PASS
```

Set `SCNP_PASS` through a private environment/secret mechanism before signing. Omitting `--keystore` produces an aligned unsigned APK. Omitting `--bridge` builds only the editor compatibility prototype. Each build requires a new stage directory outside the source checkout and refuses unknown APK/tool hashes. Existing build directories are never removed automatically.

The stage contains proprietary decoded files and the locally built APK; it must stay private. `build-manifest.json` records input/output hashes and whether the bridge/signature was included. The bridge contains only owned classes; DEX 13 supplies the authored compatibility shims, DEX 14 supplies shared auth and account UI. Samsung's existing DEX files, resources and native engine are retained.

To validate the shared standalone client after auth extraction:

```powershell
cd android
./gradlew.bat :app:testDebugUnitTest :auth-core:assembleRelease :native-bridge:assembleRelease
```

Keep the destination and account-ownership checks enabled. Two-way sync is a visible app setting; local edits remain pending in download-only mode. Broader hardware, revocation and concurrent-edit coverage is listed in the design document. Normal builds explicitly disable the isolated upload probe.
