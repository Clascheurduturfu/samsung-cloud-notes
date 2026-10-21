# Validation scope

Release **1.0.0-rc.1**. Development checks: 19–21 October 2026. Counts describe one authorized library, not product limits. Real account fixtures, captures and machine configuration are not distributed.

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

## Windows helper 0.1.3

Tested on Windows x64 with Samsung Notes 4.3.831.0. Standalone packaging includes Python/Tk and pinned dependencies/notices. Live authorized Sync now capture, detachment, read-only cloud validation, cancellation/retry and encrypted export/recovery/decrypt checks passed.

Six unit tests cover export/tamper rejection, header rejection, distinct recovery paths, cancellation and rejected validation. They use synthetic credentials and do not contact Samsung.

## Reproduce offline checks

macOS: `bash scripts/check-macos.sh` compiles both app architectures and host support utilities, then runs offline self-tests. Windows: `python -m unittest discover -s Tests -v` after installing pinned requirements. CI uses no account credentials. Signing/Keychain setup and cloud checks require an interactive Mac and are outside CI.

## Remaining scope

- Intel hardware and macOS 13 live execution.
- Complete handwriting, complex brush/eraser/rotation/image composition and native `.sdocx` import/export.
- Samsung-device rendering of every edited text shape.
- Atomic server-side conflict guarantees; the app implements a client preflight.
- Every account region/policy/revocation case and future private API behavior.
- Developer ID signing, notarization and third-party Gatekeeper distribution.

A CI pass is not proof of real Samsung sign-in or sync.
