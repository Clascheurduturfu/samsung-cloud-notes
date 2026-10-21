# Changelog

## 1.1.0 — 2026-10-21

Stable 1.1, published as Git tag **v1.1**, with downloads for all three platforms.

- Promotes 1.1.0-beta.1 unchanged apart from version metadata: the Android app, the iPhone/iPad app and the `scnotes` command line described below.
- Release downloads: universal Mac app (CLI included), Android APK and an unsigned iOS IPA for sideloading, with SHA-256 checksums.
- The Mac app re-registers as 1.1.0 at its next token renewal, keeping its installation and cache identity.
- Cloud saves from the new clients follow the Mac's verified save path but were not exercised against a live account before release; see [validation](docs/validation.md).

## 1.1.0-beta.1 — 2026-10-21

First beta of 1.1: Samsung Cloud Notes beyond the Mac app.

- **Android app** for any manufacturer (Android 8+): Kotlin/Jetpack Compose port of the protocol, native Samsung sign-in through a Custom Tab, Keystore-sealed credentials, library/folders/trash/search, typed-text editing with conflict checks, backups and drafts, drawing previews/PDF, attachments and zipped export. Samsung Notes is not required.
- **iPhone and iPad app** (iOS 16+) built from the same shared Swift core as the Mac app: native sign-in, Keychain storage, the same library and editing features, Quick Look attachments and drawing PDFs, share-sheet export and Windows import.
- **`scnotes` command line** inside the Mac app: `status`, `sync`, `list`, `folders`, `search`, `show`, `edit`, `export`, `drawing`, `login`, `logout`, with `--json` and `--offline`. Install it from the app menu.
- Shared Swift sources reorganized into `Sources/Shared`, `Sources/macOS` and `Sources/iOS`; an order-preserving portable XML tree replaces Foundation's macOS-only one on iOS, cross-checked in the self-test.
- Each device registers its own model and alias with Samsung (Mac identity unchanged).
- Offline checks for iOS and Android, and matching CI jobs.
- Version 1.1.0-beta.1; as with earlier version changes, the Mac app re-registers as 1.1.0 at its next token renewal, keeping its installation and cache identity.

See [validation](docs/validation.md#110-beta1--21-october-2026) for what this beta has and has not exercised.

## 1.0.0 — 2026-10-21

Stable packaging of the validated release candidate, published as Git tag **v1.0**.

- App display, source and bundle/build metadata now report 1.0.0.
- Universal macOS download with original icon, project/upstream notices and SHA-256 checksums.
- Native sign-in, editing, caching and account menu retain the release candidate's behavior.
- Private API, text-formatting, drawing and distribution limitations remain documented below and in the README.

## 1.0.0-rc.1 — 2026-10-21

First repository release candidate.

- Native Samsung browser login, independent Mac registration and automatic credential renewal.
- Native note/folder/trash browser, search and supported title/main-text editing.
- Revision-aware cache, drafts, archived drafts and pre-save backups.
- Approximate handwriting/PDF previews, decoded folder/attachment names and internal cache filtering.
- Account email menu with Log out; signed-out welcome with sign-in and optional Windows import.
- Numeric app-version registration migration preserving installation/cache identity.
- Original icon, local signing and a fixed signed Keychain helper.
- Optional Windows connection helper 0.1.3.
- Authentication/reverse-engineering documentation and upstream credits.

See [validation](docs/validation.md) for the tested scope. This historical entry describes the release candidate; builds are not notarized.
