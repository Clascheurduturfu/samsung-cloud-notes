# Command line (`scnotes`)

New in **1.1**. `scnotes` gives terminal and script access to the same library, cache and drafts as the Mac app.

## How it works

The command line runs inside the signed app executable (`SamsungCloudNotes --cli …`). That matters for credentials: the Keychain helper only answers its own signed app, so a separate binary could not read the saved sign-in without weakening that check. `scnotes` is a two-line shell wrapper that calls the app executable.

- It reuses the Mac app's native sign-in, automatic renewal and Keychain helper. Sign in once in the app.
- It shares the app's revision-aware cache under `~/Library/Application Support/SamsungCloudNotes/`. Unchanged notes are never downloaded twice.
- Without `--offline`, read commands refresh the index from Samsung Cloud and fall back to the cache, with a warning on stderr, when offline.

## Install

In the app: **Samsung Cloud Notes → Install Command Line Tool…**. Or from a terminal:

```sh
"/Applications/Samsung Cloud Notes.app/Contents/MacOS/SamsungCloudNotes" --cli install            # ~/.local/bin/scnotes
"/Applications/Samsung Cloud Notes.app/Contents/MacOS/SamsungCloudNotes" --cli install /usr/local/bin
```

If the directory is not on your `PATH`, the installer prints the line to add to `~/.zshrc`. Reinstall after moving the app.

## Commands

| Command | Purpose |
| --- | --- |
| `scnotes status` | Account, connection type, cache size, last sync, data directory |
| `scnotes sync` | Refresh the index and download changed or missing documents |
| `scnotes list [--folder NAME] [--trash] [--limit N]` | Notes, newest first: ID, date, title, folder |
| `scnotes folders` | Folder IDs and names |
| `scnotes search QUERY` | Case-insensitive search of titles and full typed text |
| `scnotes show NOTE [--xml]` | Title, text, attachment names and drawing page count; `--xml` prints the original cloud document |
| `scnotes edit NOTE [--title TEXT] [--body TEXT \| --body-file PATH\|-]` | Replace the title and/or typed text and save to Samsung Cloud |
| `scnotes export NOTE DIRECTORY` | Write `NOTE.samsungnote/` with `document.xml`, `text.txt` and attachments |
| `scnotes drawing NOTE OUTPUT.pdf` | Write the approximate handwriting preview |
| `scnotes login` / `logout` | Open the app to sign in / remove the saved connection (cache and drafts remain) |
| `scnotes install [DIRECTORY]` | Install or move the wrapper |

`NOTE` is a note ID, a unique ID prefix of at least four characters, or an exact title (case- and accent-insensitive). Ambiguous matches list the candidates instead of guessing.

`--json` gives machine-readable output for `status`, `list`, `folders`, `search` and `show`. `--offline` never contacts Samsung. Exit codes: `0` success, `1` failure, `2` usage error.

```sh
scnotes list --folder "Math notes" --json | jq -r '.[].title'
scnotes show 1792424464 --json | jq '{title, editable, attachments}'
printf 'Milk\nEggs\n' | scnotes edit "Shopping list" --body-file -
```

## Editing safely

`edit` follows the app's save path exactly: it downloads the current revision, refuses locked/encrypted notes and unsupported text, stores a pre-save backup under `Backups/`, uploads, then downloads again and verifies the title and text. If the note changed elsewhere in between, the save is refused.

If the app holds an unsaved draft for the same note, `edit` stops rather than overwrite it. Save or reload the note in the app, or pass `--discard-draft`; the draft is archived under `DraftHistory/` either way.

In `1.1.1-beta.3`, the Mac app also offers **Discard local changes** directly beside a stale-draft warning. It clears the active draft locally and keeps a recovery archive, including while offline. **Reload cloud copy** downloads the current note and clears the old draft only after a successful download. App and CLI saves no longer leave clean saved copies in the unsaved-draft folder.

In Mac beta `1.1.1-beta.1`, `scnotes edit NOTE --resend` republishes the current title/text with a newer native sync timestamp. This repairs saves made by older clients whose text reached Samsung Cloud but was skipped by the phone. The same revision, backup and unsaved-draft checks apply; it does not force an overwrite or bypass conflicts. New saves also verify that this timestamp advanced, in addition to checking the text readback.

The same limits as the app apply: editing replaces formatting in the main text object, drawings and attachments are retained, and creating or deleting notes is not supported.

## Diagnostics

The developer flags documented in [building](building.md) (`--self-test`, `--verify-*`, `--test-save`) are separate from `--cli` and unchanged.
