# Changelog

## 1.2.0-rc.2 — 2026-11-18

Second release candidate for 1.2.0 (Mac fixes, and the native Android port).

- **Native Samsung Notes port: release candidate.** Validated by hand on a real Pixel phone: Samsung sign-in and two-way sync work. Its version is now `1.2.0-rc.2` (native package `4.4.48.15-native-rc.2`), with the same code as `1.2.0-beta.3+6`.

- **Notes deleted in Samsung Notes leave Apple Notes too.** A note deleted or moved to the trash on another device goes to **Recently Deleted** in On My Mac, where Notes keeps it for 30 days. A note you edited in Apple Notes since the last sync is kept there instead, as an ordinary note. Notes from before this version are covered, so earlier leftovers are cleaned up on the next sync. Notes that are only locked, not downloaded yet, or belong to another Samsung account are never removed.
- **Deleting a note on another device now counts as a change**, so Apple Notes is updated straight away instead of waiting for the next edit.
- **Check for Changes Now** reads Samsung Cloud at once and writes the result into Apple Notes immediately. The menu bar icon turns into arrows and the menu shows "Checking Samsung Cloud…" while it runs, then "Up to date with Samsung Cloud" or what changed.
- **Check marks in the Sync with Apple Notes menu** follow the settings at once, whichever menu changed them.
- **The menu bar icon always comes back.** After **Stay in menu bar when closed** had been turned off once, macOS could remember the icon as hidden and leave it out the next time the option was turned on, in a later launch.

## 1.2.0-rc.1 — 2026-11-18

First release candidate for 1.2.0, for **macOS, iOS and the standalone Android client**. It includes everything from the 1.2.0 betas below.

- **Stay in the menu bar (Mac).** Turn on **Stay in menu bar when closed** in the Sync with Apple Notes menu or the app menu. Closing the window then removes the Dock icon, and Samsung Cloud Notes keeps syncing Apple Notes and Samsung Cloud from the menu bar, so Apple Notes can be used on its own.
  - The menu bar item reopens the window and can switch automatic Apple Notes sync on or off, check for changes or quit.
  - Opening the app again from Finder, Launchpad or Spotlight also brings the window and Dock icon back.
- **Sync keeps running with the window closed (Mac).** Apple Notes sync and the Samsung Cloud checks belong to the app now, not to its window. While Apple Notes is kept in sync, other devices' changes are checked every minute, in the background too.
- **The update settings panel no longer shifts** when switching between Stable and Preview.

## 1.2.0-beta.8 (automatic sync) — 2026-11-18

Preview release for **macOS, iOS and the standalone Android client**.

- **Edits save themselves.** A note saves to Samsung Cloud after a minute without changes, on every platform. This leaves less time for the same note to be edited on another device.
- **Other devices' edits arrive without Refresh.** The app checks Samsung Cloud every minute while open, every three minutes in the background on the Mac, and when it comes back to the front.
  - The check reads only the note list. The editor is not locked unless something changed.
  - A refresh no longer reloads the open note when its cloud copy is unchanged.
- **Apple Notes stays in sync automatically (Mac)**, once **Sync with Apple Notes** has run once. The toolbar menu has a switch to turn this off.
  - **Edits made in Notes appear here live**, read from Notes' database while Notes keeps running. They save to Samsung after a minute without changes. A newer edit replaces the draft the previous one became; text typed here is never overwritten.
  - **Samsung changes are written into Notes as soon as Notes has been idle for a few seconds.** Writing still needs Notes closed for a moment. It reopens behind the current app, or in front if it was in front, and only if it was running.
  - Notes is closed only when something must actually be written. An Apple edit saved back to Samsung no longer rewrites the Apple copy.
  - **Typing a note in this app closes Notes**, so one note is never edited in two places. Notes comes back in the background once the edit is saved and written.
- Pull requests #2 (nested folders) and #3 (sticky-memo previews) are merged.

## 1.2.0-beta.7 (pictures and tables sync) — 2026-11-18

Preview release for **macOS, iOS and the standalone Android client**.

- **Notes with pictures or tables sync to Samsung Notes for Windows again.**
  - Samsung's apps write `<zeroLengthSpanList>` (caret-only styles) around pictures and tables. Since 1.1.1 a save emptied that list but kept the element.
  - Samsung's list reader moves to the next tag before checking for the end of the list. An empty list therefore made it read `<text>` as an entry, and Windows rejected the note (`FAIL_PARSE_XML`, "argument out of range: i").
  - Empty `zeroLengthSpanList`/`spanOrderDataList` elements are now removed, as native apps do. Notes saved by earlier betas are flagged for repair and fixed on their next save.
- **Deleting a picture or table deletes it.**
  - The object is removed from the note and its hash tree, along with its picture file when nothing else uses it.
  - Previously the attachment stayed behind with an anchor pointing at plain text.
- **Picture anchors stay on their picture.** Text typed right after a picture or table no longer joins its anchor, and anchors stretched by earlier betas are repaired on save.
- Includes contributed pull requests, for testing:
  - **Nested folders** (#2): subfolders and their notes are listed, and folder trees collapse on the Mac.
  - **Sticky-memo previews** (#3): handwriting preview and a save button for attached `.sdocx` notes on the Mac.

## 1.2.0-beta.1 (formatting preservation) — 2026-11-16

Preview release for **macOS, iOS and the standalone Android client**. Not yet verified against a native Samsung Notes downsync; see [validation](docs/validation.md).

- **Text edits keep Samsung formatting.** Earlier versions rebuilt the whole body with one default style when saving, so bold, italic, underline, strikethrough, colours, highlights, font sizes, alignment, indentation, bullets, numbered lists and checklists written on a Samsung device were lost. The body is now parsed into opaque style ranges (`RichText`), remapped through a diff of the old and new text, and written back with a `spanOrderDataList` in Samsung's original span order. Styles this client does not understand are carried over unchanged.
  - Typing inside or at the end of a styled run extends it; a new line typed in a checklist or list continues it; deleting a line takes its paragraph style with it; merged paragraphs keep the first paragraph's style.
  - Notes whose markup cannot be modelled safely become read-only instead of being flattened.
  - Repairs of plain notes saved by pre-1.1.1 clients (`scnotes edit --resend`) keep the verified 1.1.1 encoding.
- **Formatted view (Mac and iOS).** Notes with formatting open in a read-only **Formatted** view showing styles, colours, highlights, sizes, alignment, bullets, numbers and checkboxes; **Edit text** switches to the plain editor. List and checkbox markers are best effort in this beta.
- **`scnotes show NOTE --styles [--json]`** prints a note's formatting ranges (keys, values and offsets, never the text) for diagnosing formatting issues.
- Version numbers: apps report `1.2.0-beta.1`; Android `versionCode` 10191; the separate native Android port keeps its own numbering, now `1.2.0-beta.3+6`.

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
