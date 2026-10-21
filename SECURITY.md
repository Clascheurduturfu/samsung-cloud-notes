# Security and private data

## Reporting

Use **Security → Report a vulnerability** when available. If private reporting is unavailable, open an issue asking for a private contact without vulnerability details or sensitive attachments. Never post live credentials or private notes. The current release candidate is the supported development version; no response time or Samsung support is guaranteed.

## Keep private

- Passwords, verification codes, browser cookies and active callback URLs.
- Reusable account authorization, OAuth/cloud tokens and signed download URLs.
- `.samsungconnection` exports and unlock codes; together they grant account access.
- Note XML, attachments, caches, drafts, backups and account databases.
- DPAPI recovery records, loose signing keys, P12 files and private identities.

Documented public client/package/callback identifiers are protocol constants, not user credentials. Use entirely synthetic fixtures rather than lightly redacted captures.

## Storage and logout

The Mac saves credentials through its signed Keychain helper. Caches/drafts/backups under `~/Library/Application Support/SamsungCloudNotes/` contain private note content and are not separately encrypted by the app.

Logout removes this app's saved authorization/session, clears the visible library and cancels renewal. It retains cache/drafts and does not revoke every server token, remove browser sessions or erase all local content.

The optional Windows helper uses AES-GCM exports with a DPAPI-protected recovery key. Native Mac sign-in is preferred over borrowed Windows identities.

Signing identities stay in the login Keychain. Replacing the helper or identity may require approval. Do not disable macOS security or grant broad Keychain access to avoid prompts. Builds are not Developer ID signed or notarized.
