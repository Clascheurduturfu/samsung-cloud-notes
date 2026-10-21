# Building and project layout

## macOS

`bash scripts/build-macos.sh` creates `dist/Samsung Cloud Notes.app`, generates its icon, includes notices, signs and runs offline self-tests. Both architectures target macOS 13; `BUILD_UNIVERSAL=0` builds Apple Silicon only.

The first build needs a graphical login session and unlocked login Keychain. Setup imports a local code-signing-only identity. Its public fingerprint is remembered under `~/Library/Application Support/SamsungCloudNotes/SigningIdentity.txt`; the private key stays in Keychain. Loose keys, temporary P12 and password files are removed. No system/TLS trust root is installed. Remote builds use LaunchServices for setup/signing and may require approval.

### Signing migration

The app and credential helper must share a signing certificate. The helper is reused unchanged from an existing build or `/Applications/Samsung Cloud Notes.app`, retaining its Keychain code hash across app updates.

`SIGNING_IDENTITY` selects an existing identity; the SSH signer expects its 40-character fingerprint. Switching identities does not migrate the installed helper. To build with a different identity, move the old installed app and previous build output aside, then build a fresh helper. Preserve the old app until new credential access is verified. Expect approval and possibly a new sign-in; never copy private signing keys into the repo or CI.

`bash scripts/check-macos.sh` compiles both app architectures and host support utilities, runs only offline self-tests, and removes its temporary output. It does not access Keychain, configure signing or create a distributable app.

## Source map

| Path | Purpose |
| --- | --- |
| `Sources/App.swift` | SwiftUI UI/model, drafts and diagnostics |
| `Sources/Authentication.swift` | Browser/PKCE/service authorization and registration/renewal |
| `Sources/Cloud.swift` | Notes XML, text codec, saves and backups |
| `Sources/Cache.swift` | Revision-aware index/document/asset storage |
| `Sources/Credentials.swift` | Verified credential-helper invocation |
| `Sources/Drawing.swift` | Bounded stroke decoder, preview/PDF |
| `scripts/credential-store.swift` | Fixed signed helper, caller validation and limited credential operations |
| Signing scripts | Local identity setup and signing utilities |
| `scripts/make-icon.swift` | Original icon generation |
| Windows Python scripts | Optional GUI/CLI exporter |
| `Tests/` | Synthetic Windows unit tests |
| `docs/third-party/` | Dependency/adaptation licenses |

## Diagnostics

`--self-test` is offline. Other flags in `Sources/App.swift` are tools for an explicitly authorized account: `--verify-native`, `--verify-cache`, `--verify-previews` and `--verify-cloud` read account data and may renew credentials or write caches. `--verify-signout` temporarily removes credentials and attempts restoration. `--test-save <note-id>` writes only a specially marked isolated test note; inspect its guard before use. Keep these out of unattended CI and real output out of bug reports.

## Windows

See [the helper guide](windows-helper.md). Use an isolated Python environment and keep build output in ignored `dist/`. Exports and DPAPI recovery data must never enter packages.
