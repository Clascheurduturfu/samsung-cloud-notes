# Validation scope

Current release **1.1.1** (Git tag **v1.1.1**). Previous releases: **1.1.0** (Git tag **v1.1**) and **1.0.0** (Git tag **v1.0**).

## Release 1.1.1 — 14 November 2026

Release **1.1.1** resolves two native XML parsing bugs that prevented Mac uploads (and unpatched mobile ports sharing the same upload builder) from downsyncing into official Samsung Notes clients, brings the standalone Android port (`Cloud.kt`) into parity, and merges the native Android port tooling (`1.2.0-beta.3+5`, **beta — not yet tested by the owner on physical hardware**).

- **Verified binary root causes:**
  - Native C++ serializer (`libSpen_xmlSerializer.dll`, `RichTextXmlSerializer::SortSpanListWithOrderData` at `0x516e0`): `uploadXML` replaced body text without updating `<spanOrderDataList>` or clearing `<zeroLengthSpanList>`, wrote `'span/fontSize'='1,12'` and `'paragraph/parsingState'='False'`, left `'paragraph/alignment'='0'` unclosed across lines, and encoded `<title>` with body span/section tags instead of `<?a 'paragraph/parsingState'='false'?>`.
  - Windows .NET Native parser (`SamsungNotes.dll`, `WDocObjectBase.ParseXml` at RVAs `0x64fbebb`..`0x64fbed8`): `<object timeStamp="...">` is parsed via `Convert.ToInt32`, so writing 64-bit microsecond epoch timestamps triggered `FAIL_PARSE_XML` (`ExceptionCode: 327`, Int32 overflow). Both `<object timeStamp>` and `<attributes editTime>` now keep `"0"`.
- **Live cross-device sync verification:** Repaired all six affected cloud notes from the Mac client (`scnotes edit --resend --discard-draft`) and triggered sync on Windows Samsung Notes `4.3.831.0` (`Storage.sqlite` `NoteDB` count rose from `37` to `43`, all six present with `Corrupted = 0`) and Galaxy Tab S9+ (`SM_X810`: logcat confirmed `WCon_WNote: parseXml() - end`, `compareForDownsyncSucceed()`, and `onSyncEnded() : success, mResultCode = 0`; one pre-existing conflicted local note stayed conflict-marked on tablet UI as expected).
- **Standalone Android alignment:** Updated `Cloud.kt`, `Store.kt`, `NotesViewModel.kt`, `Ui.kt`, and `OfflineTest.kt` to match `Cloud.swift` (`StyledText.encode`, `encodeTitle`, `spanOrderData`, `zeroLengthSpanList`, `timeStamp="0"`, `editTime="0"`, `syncModifiedTime`, `uploadTextDelta`, `removeDraftIfMatches`). Offline JVM unit tests passed (10 `OfflineTest` + 8 `:native-bridge` tests) and `:app:assembleDebug` built cleanly.
- **Native Android port (`1.2.0-beta.3+5`, beta):** Source-only builder/bridge included on `main`; five Python patch-profile checks passed, **but physical-device usage has not been tested by the owner yet and remains beta**.

## Local Mac draft recovery fix — 29 October 2026

Version **1.1.1-beta.3** removes the false-draft recovery loop. Earlier clients stored successfully saved cloud baselines in `Drafts`; a later remote change could make that clean baseline appear to be conflicting unsaved work. Successful app/CLI saves now clear only the matching active draft. Opening a matching leftover baseline removes it, while actual differing edits remain protected.

New isolated model/store checks cover clean-baseline migration followed by a remote edit, stale-draft recovery, offline discard, archived recovery contents, reopening without resurrection, pending debounce cancellation, reload without creating a new draft, fresh document revisions, matching-only save cleanup and failure to archive. An archive failure retains the active file and local edits. These checks use a temporary directory and no Samsung account/network access.

The universal signed build passed shared, updater-state, draft and installer checks, and was installed and reopened on the owner's Mac. A desktop-session check confirmed version 1.1.1-beta.3, the saved account and 35 cached notes. The credential helper remained byte-for-byte unchanged. The downloaded release ZIP passed its manifest SHA-256, size, CRC, version and helper checks. Dedicated Mac build, package, rollback and diagnostic files were removed; only the installed app remains running. No notes were uploaded and no GitHub release was published for this local-draft check.

## Local Mac updater and text-delta fix — 28 October 2026

Version **1.1.1-beta.2** was built for both Mac architectures, locally signed, packaged, installed and reopened. The existing credential-helper binary is unchanged and the installed app still reads its saved sign-in and 35-note cache.

- Embedded updater checks passed for version/channel selection, missing/ambiguous assets, digest failure, redirect safety, ZIP corruption/traversal/symlinks/expansion limits, a deleted release, stale channel responses, saved preferences and critical app activity. The original shared offline checks also passed.
- The existing real GitHub v1.1 Mac asset was downloaded and verified against its API digest, archive contract, architecture, publisher and credential helper. It was not installed as a downgrade.
- The actual installer replaced an isolated copy of the old app with the new bundle, relaunched it, received its transaction-specific startup acknowledgement and removed its staging/backup files. An earlier failed health check restored the isolated old bundle; injected launch-health failure and successful-swap fixture checks also passed. No user installation was used for the failure test.
- Six publication-fixture checks passed, including verifying uploaded assets before publishing and retaining the previous Preview on verification failure. The manual hosted workflow/signing-secret setup has not been run; no push or release publication is implied.
- A native text-and-pen test note reproduced HTTP 400/code 128406 for missing multipart `strokeResource` parts. A text-only delta then saved and restored its text while preserving both pages and all three stroke objects. The shipped delta method has an offline regression retaining the original opaque objects and complete hash tree.
- Both v1 and native v3 cloud responses contained the two reported Mac text additions. The owner subsequently saw the Mac revision in the phone's Samsung Note conflict dialog. Windows still reported that note as an unresolved conflict after choosing a version. Delivery to the conflict UI is confirmed; completed native conflict resolution on every device is not.

## Local Mac sync fix — 28 October 2026

Version **1.1.1-beta.1**, locally built and installed; no GitHub release published. Two reported missing Android edits were present in a fresh Samsung Cloud download, while `noteResource.syncModifiedTime` still matched the old phone revision. The native Android change-list filter compares that millisecond clock against the locally stored server timestamp and can skip such updates.

- The shared Apple save path now advances that clock monotonically, keeps attribute/object/tree edit clocks consistent, and verifies the returned native sync clock as well as title/text.
- New offline regression checks passed for clock rollback and consecutive uploads. Both Mac architectures compiled; embedded self-tests and recursive signature verification passed.
- Two affected notes were resent through the shipped CLI with `--resend`. Fresh cloud readback passed and each native sync timestamp advanced. The title/text fields and complete drawing page XML matched their pre-repair downloads exactly. Existing revision checks, pre-save backups and unsaved-draft protection remained enabled.
- The installed credential helper is byte-for-byte unchanged, and the installed executable matches the verified downloaded universal ZIP. The diagnostic and selected private note identifiers are absent from the shipped executable.
- A later phone screenshot confirmed arrival of the Mac version in Samsung's conflict dialog. Server acceptance/readback is still not proof that a native conflict resolution committed or that the phone applied the selected document.

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
