# Changelog

## 1.1.1 — 2026-11-14

Stable 1.1.1, published as Git tag **v1.1.1**, fixing native upload/downsync compatibility across **macOS**, **iOS**, and the **standalone Android** client, and adding the **native Samsung Notes Android port** (source-only builder in **beta**, untested by the owner on real hardware).

- **Native rich-text & `Int32` timestamp sync fix (Mac, iOS & standalone Android):**
  - Synchronizes `<spanOrderDataList>` with the edited body UTF-16 length and font/color spans (`3,0,<len>,1,15.0` and `1,0,<len>,1,-14342875`), clears `<zeroLengthSpanList>`, fixes `'span/fontSize'='1,15.0'` and lowercase `'paragraph/parsingState'='false'`, closes/reopens per-line paragraph markers across newlines, and encodes `<title>` with `<?a 'paragraph/parsingState'='false'?>` without span/section tags. Previously native clients failed in `RichTextXmlSerializer::SortSpanListWithOrderData`.
  - Sets `<object timeStamp="0">` on edited body/title objects and keeps/resets `<attributes editTime="0">`. Previously writing a 64-bit microsecond epoch timestamp caused Windows Samsung Notes (`WDocObjectBase.ParseXml`) to fail downsync with `FAIL_PARSE_XML` (`Int32` overflow).
  - Automatically detects and repairs legacy client-edited XML on save, including `scnotes edit NOTE --resend` (also permitted for repair on trashed notes when text is unchanged).
  - Ports `syncModifiedTime` monotonic advancement, text-only delta uploads (`uploadTextDelta`, omitting unchanged `pageList`/`contentFileList`), and non-stale draft cleanup (`removeDraftIfMatches` / **Discard local changes**) to the standalone Android Kotlin client (`Cloud.kt`, `Store.kt`, `NotesViewModel.kt`, `Ui.kt`), alongside Apple clients.
- **Native Samsung Notes Android port (`1.2.0-beta.3+5`, Beta — not yet tested on physical devices by the author):**
  - Merges the source-only native Android port tooling (`android-samsung-port/`, `android/auth-core/`, `android/native-bridge/`, [native port guide](docs/android-native-port.md)) into `main`.
  - Takes an owner-supplied Samsung Notes `4.4.48.15` APK and adds browser OAuth/SCSP sign-in, Keystore credential storage, download-only default / optional two-way sync, offline editing, and standard Android document-picker `.sdocx` export/import. No vendor APK is distributed.
  - Marked **beta**: only emulator checks have been run so far; real-device user testing is still pending.
- Includes all Mac improvements from `1.1.1-beta.1` through `1.1.1-beta.3` (in-app GitHub Releases updater behind the version number, local draft recovery cleanup, and text-only delta saves).

## 1.1.1-beta.3 (Mac local draft recovery) — 2026-10-29

- Adds **Discard local changes** beside the stale-draft warning and for ordinary unsaved edits. It works offline, preserves recovery copies and removes the active draft without changing Samsung Cloud.
- Stops storing successfully saved cloud copies as unsaved drafts; matching leftovers from older clients are cleaned up on open. Discarded edits cannot return through a pending autosave or a note reopen.
- Makes **Reload cloud copy** explicit, disables concurrent actions while reloading and keeps downloaded cache revisions consistent with the document.
- Removes duplicated channel explanations from the update popover.

## 1.1.1-beta.2 (Mac updater and drawing-safe saves) — 2026-10-28

- Click the version number for Stable/Preview update settings, persisted optional daily checks, GitHub Releases, progress and explicit Install & Restart.
- Verify release assets, SHA-256, archive safety, bundle/version/architecture and the existing publisher/helper before installation. Retain rollback until the new app acknowledges startup; block handoff during active saves/sync/sign-in and preserve drafts.
- Add universal release packaging and a manual signed-release workflow, with verified draft publication before scoped rolling Preview cleanup. No branch or release is published by adding this workflow.
- Fix HTTP 400 `strokeResource` mismatches when saving text in a note containing handwriting: send a text-only delta and retain the complete hash tree referencing the existing server-side ink/files.
- Samsung clients have detected the resent Mac revision but can still pause on a native per-note conflict. Keep both versions or compare them in Samsung Notes rather than treating cloud readback as proof of conflict resolution.

## 1.1.1-beta.1 (Mac sync fix) — 2026-10-28

- Advances the native note sync timestamp on saves. Previously, Samsung Cloud could return the edited text successfully while Samsung Notes on Android skipped the unchanged timestamp.
- Verifies that the native sync timestamp advanced before reporting success, while retaining the existing text readback, revision checks, drafts and backups.
- Adds `scnotes edit NOTE --resend` to repair previously saved text without changing its contents or bypassing draft/conflict checks.
- Adds offline regression checks for a backwards clock and consecutive saves. This local beta is separate from the unreleased native Android port; the latest published Mac release remains v1.1.

## 1.2.0-beta.3+5 — 2026-10-24

Local native Android beta; the stable Apple and standalone Android clients retain their versions.

- Runs the owner-supplied Samsung Notes 4.4.48.15 editor on generic Android, with independent browser sign-in and Keystore-protected credentials.
- Adds native cloud downloads and optional two-way note/folder sync, offline editing, an email account menu, and standard Android file export/import.
- Fixes cached page images hiding valid handwriting after reopening a document on the test emulator, while retaining native stroke objects.
- Includes a hash-pinned source-only builder and sanitized authentication/compatibility findings. Vendor-derived APKs and private account material remain outside Git.
- Validated on a generic ARM64 API 37 emulator, including independent Mac readback of a native upload/update and offline text/pen export/reimport. Real non-Samsung hardware and broader conflict/revocation coverage remain pending; see [native validation](docs/android-native-port.md).

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
