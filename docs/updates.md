# Mac app updates

Click the **version number** below the account menu to open update settings. The app checks published GitHub Releases, not branch source archives.

- **Stable** offers newer final Mac releases. **Preview** offers marked Mac prereleases and newer Stable releases.
- The selected channel and optional daily launch check are saved. Switching to Stable never automatically downgrades a newer Preview installation.
- **Check for Updates** runs on demand. **Install & Restart** appears when a verified compatible package is available. Installation is explicit.
- Saves, sync and sign-in block the install handoff. Unsaved supported drafts are persisted before restarting. Preferences, notes and credentials are outside the replaced bundle.
- **Open GitHub Releases** provides the manual fallback for offline/rate-limited checks, private repositories, unavailable assets and signing changes. This public feed needs no GitHub token.

## Package and trust contract

The bundle defaults to repository `Clascheurduturfu/samsung-cloud-notes` and asset prefix `SamsungCloudNotes`; the packager records these in `UpdateRepository` and `UpdateAssetPrefix`. The app identity remains `local.samsung-cloud-notes`.

The single deterministic package name is `SamsungCloudNotes-VERSION-macOS.zip`, containing the universal `Samsung Cloud Notes.app`. GitHub's asset API must provide its ID, size and `sha256:` digest. Missing/ambiguous assets or missing digests are rejected. The release feed is bounded to its first 300 records; drafts and unsupported version formats are ignored. Stable final tags retain compatibility with the older `v1.1` spelling. New publication uses full three-component versions.

Downloads require HTTPS, expected GitHub redirect hosts, a byte limit and an ephemeral session. Authorization is stripped outside the API host; the public implementation sends no access token. The client checks size and SHA-256, ZIP central/local paths, expansion limits, entry types, bundle identity/version, processor support, publisher signature and the unchanged credential-helper binary. The current bundle has no framework symlinks, so package symlinks are explicitly unsupported. SHA-256 from release metadata proves transfer integrity; the existing app's signing requirement supplies publisher authentication.

The installer waits at most 30 seconds for the old process to exit, copies beside the destination on the same volume and retains the previous bundle. It relaunches through Launch Services and waits at most 30 seconds for a transaction-specific app-ready acknowledgement. A failed launch/health check restores the previous app. Failed transactions retain diagnostic state when needed; successful transactions remove only their owned staging and rollback files. The helper requests no elevation and never reads Samsung credentials.

## Prepare and publish

`scripts/package-macos-release.py` creates the ZIP, `SHA256SUMS.txt` and `macos-release.json` from an already signed universal app. `--trusted-previous-app PATH` also enforces the existing signing requirement and identical credential helper.

The manual `.github/workflows/release-macos.yml` workflow uses **main for Stable** and **preview for Preview**. It does not run publication on normal pushes. A Preview release carries `<!-- samsung-cloud-notes:update-channel=preview -->` in its body. Its version must advance numerically, for example `1.1.1-beta.2` to `1.1.1-beta.3`.

Before enabling hosted signed builds, configure the repository's `NOTES_SIGNING_P12_BASE64`, `NOTES_SIGNING_PASSWORD` and `NOTES_SIGNING_IDENTITY` secrets using the existing publisher identity. This feature does not export or change a local signing identity. The workflow reuses the hash-pinned v1.1 credential helper and verifies the new app against that trusted baseline. A new/ad-hoc CI identity cannot silently replace a locally trusted installation.

Publication creates or resumes a compatible draft targeting the exact reviewed commit. It verifies uploaded/downloaded bytes and GitHub digests before publication, then rediscovers the published package through the release feed. Only afterward does it retire superseded marked **Mac Preview release records**. Stable history, other platform streams and all underlying Git tags remain. An already published version is never overwritten. Signing setup, branch pushes and release publication remain explicit operator actions.

## Validation

The Mac self-tests cover semantic/prerelease ordering, Stable/Preview filtering, stream provenance, channel-switch stale responses, saved preferences, critical activity, asset ambiguity, missing/bad digests, redirects, deleted releases and unsafe/corrupt/oversized ZIPs. The installer exercises successful swap and health-failure rollback in isolated fixture directories. The publishing tests verify scope, numeric Preview versions, failure retention and verify-before-retire ordering without calling GitHub.

A development check also downloaded the existing public v1.1 package and verified its real GitHub digest, archive, architecture, signature and preserved helper against the installed app; it did not install a downgrade. No newer release is claimed published merely because a local build or test succeeds.
