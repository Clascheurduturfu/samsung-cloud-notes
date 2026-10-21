# Validation scope

Current release **1.1.0** (Git tag **v1.1**); its checks are listed under [1.1.0-beta.1](#110-beta1--21-october-2026), the code it promotes. The previous release is **1.0.0** (Git tag **v1.0**).

## 1.0.0

Release **1.0.0** (Git tag **v1.0**). Functional checks below were performed on the release-candidate code; stable changes are version metadata and distribution documentation. Development checks: 19–21 October 2026. Counts describe one authorized library, not product limits. Real account fixtures, captures and machine configuration are not distributed.

| Area | Completed development check |
| --- | --- |
| Build/install | Universal arm64/x86_64, macOS 13 target, Swift 6.4 in Swift 5 mode; installed/opened on Apple Silicon; recursive signature and installed/archive executable comparison passed |
| Offline | Embedded text/span/cursor, connection decryption, opaque-object retention, folder decoding and related checks passed |
| Native sign-in | User completed browser login/verification; independent Notes authorization, registration and cloud access succeeded |
| Renewal | Forced service/cloud renewal and deliberately rejected-bearer recovery passed without Windows |
| Version migration | Same installation re-registered under numeric 1.0.0; token issuance and stable cache identity retained |
| Keychain | GUI-launched signed app read saved credentials/downloaded a document; changed app binaries used the fixed helper; unrelated parent refused |
| Logout | Credential removal and visible-state reset checked; diagnostic restored the original connection from memory |
| Cloud reads | RC listed 36 records (34 normal, two trash), two folders and downloaded a document |
| Cache | Earlier native checks restored 35 records offline and downloaded zero unchanged documents on warm refresh; renewal retained cache identity |
| Drawings | Five pages / 772 supported strokes; PDF page counts checked and a drawing raster/PDF inspected |
| Writes | Isolated note saved accented, Japanese and emoji text; cloud download confirmed it |
| Conflict refusal | Stale-revision test refused without changing the isolated note |

User feedback confirmed folder, drawing, attachment and layout fixes, and native sign-in. Remote capture/Accessibility were unavailable; automated checks are not exhaustive visual/UI validation.

### Stable v1.0 package

The 1.0.0 universal app was built separately from the installed app. Its offline self-tests and recursive signature verification passed; both the main executable and unchanged credential helper contain Apple Silicon and Intel slices. The downloaded ZIP was decoded and checked for version metadata, executable permissions, icon and project/upstream license notices. Packaged executable hashes matched the Mac build. These packaging checks did not repeat browser sign-in or write to the account. The prior release-candidate cloud checks above remain the functional evidence.

## 1.1.0-beta.1 — 21 October 2026

Development checks on Apple Silicon with Xcode 27.1 (Swift 6.4, Swift 5 mode), an iPhone 17 simulator, and an Android 17 (API 37) arm64 emulator with Chrome. One authorized account; the user completed every browser login and verification.

| Area | Completed development check |
| --- | --- |
| Mac app | Sources moved to `Sources/Shared` + `Sources/macOS`; signed Apple Silicon build with the existing identity and unchanged helper; offline self-tests passed, including the new portable-XML checks and the Foundation cross-check |
| Mac live read | The 1.1 build read the existing 1.0 native sign-in through the unchanged helper and loaded the live index and cache |
| `scnotes` (read) | Live `status`, `folders`, `list`, `search`, case-insensitive title resolution, `show`/`--json`, `--offline`, wrapper `install`; unknown notes/options and offline `edit` returned exit codes 1/2 |
| iOS build | Simulator build; shared self-tests passed inside the simulator |
| iOS sign-in | Native browser sign-in, Notes authorization, registration and library sync (34 notes, two folders) succeeded; cached library restored on relaunch before refresh |
| Android build | Debug and minified release APKs; 10 JVM unit tests mirroring the Swift self-test vectors passed |
| Android sign-in | Custom Tab sign-in returned through the `ms-app` intent filter; Notes authorization, registration and sync of 34 notes succeeded; cached library restored on relaunch; a note with accented, Japanese and emoji text rendered correctly |
| Android first-run denial | A fresh emulator browser profile got *Access denied (400)* on the first SDK page; controlled reloads showed the login form for both Mac-identical and Android device fields, and the app's flow succeeded after one visit to account.samsung.com |

Not yet exercised in this beta: cloud **saves** from the iOS app, the Android app or `scnotes edit` (they share or port the Mac's verified save path, but no write was made); export, attachments and drawing previews on mobile against real notes; physical iPhones/iPads and Android phones; iPad layout; the Mac's 1.1.0 re-registration (its saved cloud token was still valid); Android tablets/foldables; process death during Android sign-in; Intel Macs.

## Windows helper 0.1.3

Tested on Windows x64 with Samsung Notes 4.3.831.0. Standalone packaging includes Python/Tk and pinned dependencies/notices. Live authorized Sync now capture, detachment, read-only cloud validation, cancellation/retry and encrypted export/recovery/decrypt checks passed.

Six unit tests cover export/tamper rejection, header rejection, distinct recovery paths, cancellation and rejected validation. They use synthetic credentials and do not contact Samsung.

## Reproduce offline checks

macOS: `bash scripts/check-macos.sh` compiles both app architectures and host support utilities, then runs offline self-tests. iOS: `bash scripts/check-ios.sh` builds for the simulator and runs the shared self-tests in a simulator. Android: `bash scripts/check-android.sh` runs the JVM unit tests and assembles a debug APK. Windows: `python -m unittest discover -s Tests -v` after installing pinned requirements. CI uses no account credentials. Signing/Keychain setup and cloud checks require an interactive Mac and are outside CI.

## Remaining scope

- Intel hardware and macOS 13 live execution.
- Complete handwriting, complex brush/eraser/rotation/image composition and native `.sdocx` import/export.
- Samsung-device rendering of every edited text shape.
- Atomic server-side conflict guarantees; the app implements a client preflight.
- Every account region/policy/revocation case and future private API behavior.
- Developer ID signing, notarization and third-party Gatekeeper distribution.
- App Store / Play Store distribution; mobile builds are for personal sideloading.

A CI pass is not proof of real Samsung sign-in or sync.
