# Native Samsung authentication

The implementation adapts the account bootstrap and SCSP protocol described in Charles Bel's MIT-licensed samsung-re-health. It uses Apple's AuthenticationServices, Security, CryptoKit and CommonCrypto frameworks; no Samsung SDK is bundled.

## Account and Notes authorization

1. Fetch Samsung's ANDROIDSDK entry point over HTTPS. Validate its sign-in URI and public key. `chkDoNum` may be a JSON string.
2. Generate random state, a PKCE verifier/challenge and a persistent installation identifier. Encrypt the service parameters using Samsung's RSA/AES envelope format.
3. Open ASWebAuthenticationSession. The user enters their password and completes verification on Samsung's page. The SDK requires an accepted Android browser package identifier even when Safari handles the actual page.
4. Check the callback scheme/authority, age, unique fields and encrypted state. Normalize a bare Samsung account hostname to HTTPS, then permit only Samsung account authorities. Exchange the PKCE-bound code for the reusable account authorization.
5. Authorize the Notes client with a second PKCE exchange. Credentials are stored through the signed Keychain helper, never in the note cache or ordinary logs.

## Cloud identity

Register the installation with `POST https://play.samsungcloud.com/identity/v1/register`, using the Notes service authorization, account identifier and a SHA-256 installation identifier in the SCSP headers. The returned registration identifier is stored in Keychain. `POST /identity/v1/tokens` issues the bearer accepted by the Notes document API.

The verified registration body uses the server's Android compatibility profile (SDK 35, platform 6.0.0, type phone) with model Mac and alias Samsung Cloud Notes for Mac. The server rejected the macOS/desktop profile during development. These compatibility fields do not describe an emulated operating system or a hidden Android dependency. Samsung may classify the device as Android.

The older `/user/v7/activate` route issued a device ID, but its `/auth/sc/tokens/v1/app` exchange was rejected for this client. That exploratory route is not used by the shipped implementation.

## Renewal and cache

The app checks the cloud expiry before requests. Expired Notes service access attempts its refresh grant; rejected refresh grants fall back to authorization using the reusable Samsung account state. A rejected cloud bearer triggers one renewal and retry. Network failures retain the local cache and drafts. If Samsung revokes the reusable account authorization, the user must sign in again.

Native cache directories are keyed by account and installation identity, not bearer contents. Renewing credentials therefore preserves cached documents and attachments. Native renewal does not require a Windows credential file or running Windows application.

## Keychain identity across local builds

Ad-hoc builds change their code hash. A self-signed certificate gives a stable designated requirement, but this Mac also assigned a code-hash partition to newly created Keychain items. A persistent certificate alone did not prevent prompts across changed binaries.

The small CredentialStore helper is reused byte-for-byte across app builds, retaining its Keychain code hash. Before handling a request, it checks the live parent process's bundle identifier and signing certificate. The app checks the helper's identifier and matching certificate before launching it. Requests and replies use anonymous pipes; the helper permits only the app's named credential items. It exits after each request. No daemon, local HTTP port or plaintext credential file is used.

The signing identity's private key stays in the user's login Keychain. The setup script removes loose private-key, encrypted identity and password files on exit. It does not add TLS trust roots or change system trust. The app is locally signed, not Developer ID signed or notarized. Replacing the helper or switching signing identities may require a fresh Keychain approval.

## References

- https://github.com/charlesbel/samsung-re-health
- https://developer.apple.com/library/archive/technotes/tn2206/_index.html
- https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements

## Account menu (1.0.0-rc.1)

The signed-in sidebar shows the account email as a menu with Log out. Signing out cancels renewal, removes the native authorization and saved cloud session from Keychain and clears the visible account/library. Local drafts and cache remain. The welcome screen then offers Sign in with Samsung (or the optional Windows import). This is an app logout, not a Samsung-wide browser/device sign-out or token revocation.

See [the complete research note](reverse-engineering.md) for encryption fields, analysis landmarks and rejected routes.
