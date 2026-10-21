# Building and project layout

## macOS

`bash scripts/build-macos.sh` creates `dist/Samsung Cloud Notes.app`, generates its icon, includes notices, signs and runs offline self-tests. Both architectures target macOS 13; `BUILD_UNIVERSAL=0` builds Apple Silicon only.

The first build needs a graphical login session and unlocked login Keychain. Setup imports a local code-signing-only identity. Its public fingerprint is remembered under `~/Library/Application Support/SamsungCloudNotes/SigningIdentity.txt`; the private key stays in Keychain. Loose keys, temporary P12 and password files are removed. No system/TLS trust root is installed. Remote builds use LaunchServices for setup/signing and may require approval.

### Signing migration

The app and credential helper must share a signing certificate. The helper is reused unchanged from an existing build or `/Applications/Samsung Cloud Notes.app`, retaining its Keychain code hash across app updates.

`SIGNING_IDENTITY` selects an existing identity; the SSH signer expects its 40-character fingerprint. Switching identities does not migrate the installed helper. To build with a different identity, move the old installed app and previous build output aside, then build a fresh helper. Preserve the old app until new credential access is verified. Expect approval and possibly a new sign-in; never copy private signing keys into the repo or CI.

`bash scripts/check-macos.sh` compiles both app architectures and host support utilities, runs only offline self-tests, and removes its temporary output. It does not access Keychain, configure signing or create a distributable app.

The command line is part of the app executable (`--cli`), so every Mac build includes it; see [the CLI guide](cli.md).

## iOS

`iOS/SamsungCloudNotes.xcodeproj` uses folder-synchronized groups for `Sources/Shared`, `Sources/iOS` and `iOS/Resources`; adding a Swift file to those folders needs no project edit. A build phase copies the project and upstream notices into the app's `Notices/` folder. Set your own team for device builds.

`bash scripts/check-ios.sh` builds for the simulator without signing, checks the bundled notices, then runs `--self-test` (the shared `SelfTest.run()`, including the portable XML checks) inside an iPhone simulator. It shuts down a simulator it had to boot.

## Android

`android/` is a Gradle project (AGP 9, Kotlin built in, Jetpack Compose, minSdk 26). The version name is read from `appVersion` in `Sources/Shared/Cloud.swift`, so all clients report one release. License notices are generated into the APK's `assets/notices/`. `local.properties` (your SDK path) is ignored.

`bash scripts/check-android.sh` runs the JVM unit tests in `OfflineTest.kt` (the Swift self-test vectors) and assembles a debug APK. Release builds are minified and signed with the local debug key unless `SCN_ANDROID_KEYSTORE` and `SCN_ANDROID_KEYSTORE_PASSWORD` are set. `bash scripts/build-android.sh` sets them from a keystore outside the repository and its Keychain password, and copies the APK to `dist/`.

## Release packaging

`scripts/build-macos.sh`, `scripts/build-android.sh` and `scripts/build-ios.sh` (unsigned IPA for sideloading) write the release downloads to `dist/`. Zip the Mac app with `ditto -c -k --sequesterRsrc --keepParent` and publish `SHA256SUMS.txt` for all three files. Never commit keystores, IPAs, APKs or the signing identity.

## Source map

| Path | Purpose |
| --- | --- |
| `Sources/Shared/Model.swift` | Library/draft/save model shared by the Mac and iOS apps |
| `Sources/Shared/Authentication.swift` | Browser/PKCE/service authorization and registration/renewal |
| `Sources/Shared/Cloud.swift` | Notes XML, text codec, saves and backups; `appVersion` for every client |
| `Sources/Shared/Cache.swift` | Revision-aware index/document/asset storage |
| `Sources/Shared/Drawing.swift` | Bounded stroke decoder, preview/PDF |
| `Sources/Shared/PortableXML.swift` | Order-preserving XML tree used where Foundation's is unavailable (iOS) |
| `Sources/Shared/Platform.swift` | Per-platform device model, name and user agent |
| `Sources/Shared/SelfTest.swift` | Offline self-tests run by the Mac and iOS apps |
| `Sources/macOS/App.swift` | Mac SwiftUI interface, file panels and diagnostics |
| `Sources/macOS/CLI.swift` | `scnotes` command line |
| `Sources/macOS/Credentials.swift` | Verified credential-helper invocation |
| `Sources/iOS/` | iPhone/iPad interface and Keychain storage |
| `iOS/` | Xcode project and asset catalog |
| `android/` | Kotlin/Compose Android app and JVM tests |
| `scripts/credential-store.swift` | Fixed signed helper, caller validation and limited credential operations |
| Signing scripts | Local identity setup and signing utilities |
| `scripts/make-icon.swift` | Original icon generation (`--full-bleed` for the iOS icon) |
| `scripts/check-*.sh` | Offline checks per platform, as run by CI |
| Windows Python scripts | Optional GUI/CLI exporter |
| `Tests/` | Synthetic Windows unit tests |
| `docs/third-party/` | Dependency/adaptation licenses |

## Diagnostics

`--self-test` is offline. Other flags in `Sources/macOS/App.swift` are tools for an explicitly authorized account: `--verify-native`, `--verify-cache`, `--verify-previews` and `--verify-cloud` read account data and may renew credentials or write caches. `--verify-signout` temporarily removes credentials and attempts restoration. `--test-save <note-id>` writes only a specially marked isolated test note; inspect its guard before use. Keep these out of unattended CI and real output out of bug reports.

## Windows

See [the helper guide](windows-helper.md). Use an isolated Python environment and keep build output in ignored `dist/`. Exports and DPAPI recovery data must never enter packages.
