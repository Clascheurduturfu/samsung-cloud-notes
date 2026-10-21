# Samsung Notes interoperability findings

Research dates: 19–21 October 2026. Maintained with release **1.0.0** (Git tag **v1.0**).

These are observations of Samsung's private protocols and particular Windows builds, not a public API specification. The document deliberately contains no live tokens, cookies, passwords, account IDs, notes, machine addresses or signing keys. Public client identifiers and package names below are protocol constants, not credentials.

## What came from where

| Area | Evidence / contribution |
| --- | --- |
| Notes list, document XML, upload and device tagging | Static analysis of the installed Windows sync library, scoped runtime observation and direct cloud checks |
| Account bootstrap, encrypted browser parameters, callback and SCSP identity | Charles Bel's MIT-licensed [samsung-re-health](https://github.com/charlesbel/samsung-re-health), reimplemented/adapted in Swift and tested with Notes |
| Account client IDs and older cloud endpoints | Installed Samsung Account database metadata and native binary analysis |
| Ink framing and point channels | Actual cloud XML plus [sdocx format research](https://github.com/twangodev/sdocx/tree/main/docs/reverse-engineering) |
| Keychain and local signing behavior | Direct experiments on macOS; Apple's code-signing documentation |

The Mac app bundles no Samsung executable, Android runtime or Samsung SDK. The upstream authentication implementation's MIT license is included in `third-party/samsung-re-health-LICENSE.txt` and Mac app resources. The Notes upload client was established separately; the file-parser projects did not supply that cloud write implementation.

## Inspected artifacts and practical analysis methods

- Samsung Notes for Windows **4.3.831.0**: `SamsungNotes.dll`, `SamsungNotesSync_withSDK.dll`, `SyncUtilComponent.dll`.
- Samsung Account for Windows **1.26.6021.0**: `SAClient.dll`, its package metadata and `SamsungAccountInfo.db`.
- The account library is a native PE containing .NET/native compilation artifacts, not an ordinary CIL assembly that a managed decompiler can simply reconstruct. This made native disassembly, frozen managed strings, resources and runtime observations useful.
- Ghidra targeted decompilation of `.pdata` function ranges was more practical than assuming full managed metadata was available. For large files, `pefile.PE(..., fast_load=True)` avoided expensive initial parsing.
- A frozen managed string's object header was observed 12 bytes before its UTF-16 characters, with a length at object offset +8. Native image base and section mappings must be read from each exact PE; offsets below are version-specific.
- RIP-relative string references and direct call sites helped select small functions for decompilation. Some strings lead only to static initializers; that is not proof that the surrounding initializer implements the request itself.
- The fallback Windows exporter hooks `WindowsCreateString` and `WindowsCreateStringReference`, restricts callers to the Notes sync module, and accepts only bounded strings starting with `Bearer `. It detaches before validating/exporting. Broader exploratory captures and original binaries are not part of the source distribution.

### Useful account-library landmarks

For the inspected `SAClient.dll`, image base `0x180000000`:

| Virtual address / raw offset | Observed role |
| --- | --- |
| `0x183805d40` | Builds the older application cloud-token request |
| `0x183805f50` | Adds user/app/access-token/device headers |
| `0x183806360` | Builds the older cloud service activation request |
| `0x1838059a0` | Caller using `access_token`, `client_id`, `user_id`, `dvcId` dictionary keys |
| `0x183805fd0` | Activation caller also taking `user_body` |
| `0x182b6a4a0`, `0x182b6a500` | Select/derive DPAPI entropy |
| raw `0x1719024` | Embedded .NET resource stream header |
| raw `0x1e76b44`, `0x1e76b7c` | `/user/v7/activate`, `/auth/sc/tokens/v1/app` UTF-16 strings |

These are research landmarks, not stable hooking targets for arbitrary versions. In the inspected main Notes DLL, `0x188758850` built a `/user/v6/activate` request. Newer SDK strings also included `/identity/v2/`, `/register` and `/token/renew`; their presence did not establish a working v2 client implementation in this project.

## Authentication: separate layers, separate credentials

A Samsung account login is not itself a Notes API bearer. The working chain is:

```text
Samsung browser login + PKCE
    -> reusable Samsung account authorization
    -> Notes service authorization + PKCE
    -> Notes OAuth access token
    -> SCSP installation registration
    -> SCSP cloud bearer
    -> Notes XML/document API
```

The short service OAuth credential and the much longer cloud bearer are different tokens. A captured working Windows bearer had five JWE segments; the app treats it as opaque, without attempting to decrypt its payload. Token lengths are observations, not a reliable parser or validation rule.

### 1. Account entry point and browser envelope

Working entry point:

`GET https://account.samsung.com/accounts/ANDROIDSDK/getEntryPoint`

Relevant response fields: `signInURI`, `pkiPublicKey`, `chkDoNum`; other fields included sign-out, signup/password URIs and `pbeKySpcIters`. Importantly, `chkDoNum` was returned as the **string** `"1"`. Requiring a JSON integer caused the initial "incomplete sign-in configuration" failure.

Public bootstrap client ID: `yfrtglt53o`. Public Notes service client ID: `tcl0p60gnz`.

The registered callback URI used by the tested bootstrap is:

```text
ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358
```

This is an existing registered callback identifier, not a new custom Samsung developer registration for this app. ASWebAuthenticationSession handles the callback for the current sign-in attempt.

Browser parameter encryption, matching the reference implementation:

1. Generate random state, a PKCE verifier and SHA-256/S256 challenge, plus a random installation identifier.
2. Take Base64(SHA256(UTF8(decimal `chkDoNum`))) as the PBKDF2 password.
3. Generate a random 16-byte salt; derive a 16-byte key using PBKDF2-HMAC-SHA256 and `chkDoNum` iterations.
4. RSA-PKCS1-v1_5 encrypt the Base64 representation of the derived key using the entry-point public key. Apple's SecKey import needs the RSA material extracted from the SPKI wrapper.
5. Encrypt the service JSON with AES-128-CBC, random 16-byte IV and PKCS#7 padding.
6. Form an envelope containing string `chkDoNum`, Base64 `svcEncParam`, Base64 `svcEncKY` and hex `svcEncIV`. Base64-encode that JSON for `svcParam`.
7. Open the validated `signInURI` with `locale`, `svcParam` and `mode=C`.

These algorithms describe Samsung's compatibility protocol, not a recommendation for designing a new authentication scheme. The HTTPS transport remains essential. Form parameters preserve literal plus signs; query construction must not accidentally turn Base64 `+` characters into spaces.

The payload includes `clientId`, PKCE fields, `state`, `redirect_uri`, device identifiers/model/name/OS metadata, `deviceType=APP`, encryption flags and the SDK's compatibility flags. Passwords and verification codes are entered only on Samsung's browser page.

### Browser-not-supported finding

The encrypted payload's `deviceInfo` mattered independently of the real browser user agent:

- `Apple|local.samsung-cloud-notes` and tested Safari identifiers produced Samsung's "Browser not supported" page, including when the same URL was opened in supported browsers.
- The reference SDK browser identifier `Google|com.android.chrome` reached the login form while Safari handled the actual Mac web session.
- The app therefore uses that compatibility identifier. Its visible device model/name/OS metadata still identify the Mac at account bootstrap.

This is not evidence that Safari itself cannot authenticate. The observed rejection was tied to this SDK request metadata.

### 2. Encrypted callback and master authorization

The callback values were hex-encoded encrypted strings. Samsung's callback decryption uses AES-128-ECB with PKCS#7 padding, a key formed from the first 16 UTF-8 bytes of the supplied string and zero padding if shorter.

- Decrypt callback `state` using the original request state to obtain the response key.
- Use that response key to decrypt `auth_server_url`, `code` and `retValue`.
- The returned authority needed normalization: a bare hostname and case differences must not be rejected simply for lacking the expected spelling. Normalize to HTTPS and lowercase the hostname, then enforce Samsung account domain restrictions. Do not accept arbitrary callback-provided destinations.
- Verify callback scheme/authority/path, age (15-minute bound), unique nonempty fields and no unexpected URL user information. Query and fragment fields are considered together, including duplicate detection.

Exchange the one-time code at the validated regional authority's `/auth/oauth2/authenticate` with form fields:

```text
grant_type=authorization_code
serviceType=M
client_id=yfrtglt53o
code=<ONE_TIME_CODE>
code_verifier=<ORIGINAL_PKCE_VERIFIER>
username=<DECRYPTED_LOGIN_IDENTIFIER>
physical_address_text=<INSTALLATION_IDENTIFIER>
```

The reusable result includes `userauth_token` and the user identifier. This reusable authorization is a secret even though it is not the user's password.

### 3. Notes service authorization

Use a fresh PKCE verifier/challenge for the Notes service:

`GET <VALIDATED_AUTHORITY>/auth/oauth2/v2/authorize`

Parameters: `response_type=code`, `serviceType=M`, `client_id=tcl0p60gnz`, `code_challenge`, `code_challenge_method=S256`, `childAccountSupported=Y`, `userauth_token`, `physical_address_text`, `login_id`.

Exchange the returned code with `POST /auth/oauth2/token`, using `grant_type=authorization_code`, the Notes client ID, an empty `client_secret`, the physical-address identifier and the new verifier. The implementation also honors an `auth_data.userId` supplied by service authorization.

Service `expires_in` values must handle numeric strings as well as JSON numbers. Treating only NSNumber as valid previously made a freshly issued token appear expired.

### 4. The working Notes cloud registration

Host: `https://play.samsungcloud.com`.

Headers include `x-sc-app-id` (Notes client ID), `x-sc-access-token` (Notes OAuth token), `x-sc-uid`, `x-sc-cdid`, `x-sc-app-version`, `Accept` and `User-Agent`.

The working `x-sc-cdid` is a **64-character hexadecimal SHA-256** of the persisted random installation ID. It is not the rotating bearer and does not need a hardware serial number.

`POST /identity/v1/register` accepted this shape (all identifiers here are illustrative):

```json
{
  "app": { "version": "1.0.0" },
  "device": {
    "osType": "android",
    "osVersion": "35",
    "platformVersion": "6.0.0",
    "type": "phone",
    "countryCode": "FRA",
    "modelName": "Mac",
    "alias": "Samsung Cloud Notes for Mac",
    "osUserId": "0"
  }
}
```

The response supplies `registrationId`. `POST /identity/v1/tokens` with the same identity headers returns `tokenType`, `accessToken` and `expiresAt`. The returned bearer was accepted by the Notes document API.

The tested macOS/desktop profiles returned body-validation errors. The accepted profile is explicitly an Android compatibility profile, with a Mac model/alias. Samsung may categorize this connection as Android. This is not an Android emulator or a dependency on Samsung Notes for Windows.

When a release-candidate label is used, SCSP still uses the numeric portion (for example `1.0.0`); SDK binary strings showed a restricted version grammar. The stable v1.0 release uses `1.0.0` in both app and bundle version metadata.

The first forced renewal after the 0.2.0 → 1.0.0 version change returned HTTP 400, code `40001001`. Re-registering the **same installation/CDID** with the new numeric app version, then requesting a new bearer, resolved it. The app now persists `registeredAppVersion` and re-registers when it differs from the running numeric version. Clearing the old cloud bearer after registration ensures the new registration is actually exercised. Forced renewal/rejected-bearer recovery then passed without changing the account/device cache identity.

### 5. Renewal and rejection recovery

- Check cloud expiry before authenticated requests, with a short safety margin.
- Renew expired service access using its refresh grant. The tested grant could return HTTP 400; a rejected grant falls back to Notes authorization using the reusable master account state, without a browser or Windows session.
- Renew the cloud bearer through `/identity/v1/tokens`.
- A cloud HTTP 401/403 gets one renewal/retry. Do not loop indefinitely or blindly retry arbitrary writes after network failures.
- If master account authorization itself is revoked, the sign-in action opens the Samsung browser again.
- Keep account and installation identity stable across renewal so the note cache survives bearer changes.

A native Mac check forced service/cloud renewal, deliberately supplied a rejected bearer and then loaded the same library. The isolated Mac write/readback check also used the independent Mac identity, not a Windows bearer.

## Rejected / exploratory cloud paths

These findings are useful for avoiding dead ends; they are not alternative shipped authentication flows.

| Route / observation | Result and limit |
| --- | --- |
| `/user/v7/activate` with Notes OAuth headers | Could issue a 36-character device ID; this was not the JWE bearer needed by Notes |
| `/auth/sc/tokens/v1/app` | HTTP 403, code `101001`, even after the older activation; did not establish a working Notes exchange |
| `/identity/v2/user/register` | HTTP 400, code `40001401`, "Request body - required" with the exploratory body; endpoint strings in the binary alone did not supply a working schema |
| macOS/desktop profiles with v1 registration | HTTP 400, code `40000000`, body invalid; accepted Android profile is used instead |
| Bare/mixed-case account authority | Initial overly strict validation rejected an otherwise usable callback; canonicalization plus domain checks fixed it |

Older activation bodies also produced misleading validation paths. Errors referred to `service.servicePackage`, while the JSON key expected by the inspected implementation was **`service.package`**. Required device fields included `osType`, `osVersion`, `model`, `deviceType` and nested `deviceIds.cdid`. Strings `"10"` and `"05"` appeared in the inspected desktop activation code. Completing this activation did not prove that its ID could authorize Notes requests.

## Windows account storage and fallback exporter

`SamsungAccountInfo.db` contained `ClientData`, `ProfileData` and device metadata. `ClientData` held access/refresh token fields and registered IDs including the shared account client and Notes client. Token columns were DPAPI-protected Base64, not directly usable plaintext bearer strings.

The inspected account library selected entropy from embedded resources. Where `SerialSecret` was available, the effective optional DPAPI entropy was:

```text
PBKDF2-HMAC-SHA1(
  UTF8(resource SerialSecret),
  UTF8(resource SaltString),
  iterations=30,
  outputBytes=16
)
```

UTF-8 for both inputs was confirmed against the authorized account's protected values. The resource names and derivation are documented; the resource values, decrypted tokens and database contents are deliberately omitted. This research was not needed for the final independent Mac sign-in. A protected Windows service token is still not interchangeable with a Notes cloud bearer.

The optional exporter instead captures the existing Notes cloud bearer during Sync now, detaches and checks Notes access read-only before export. Its envelope contains a 12-byte random nonce and AES-256-GCM ciphertext/tag, Base64-wrapped in a versioned JSON file. A separate random 32-byte key is shown as the connection code and retained under Windows DPAPI, keyed by the original export path. Neither the connection file nor its unlock code belongs in a repository.

Borrowing a Windows bearer also borrows its device identity. The Windows app was observed skipping downloads of edits tagged as its own device. Merely adding device-ID headers did not fix that; some were rejected by the gateway. Native Mac account/SCSP registration provides a separate client identity.

## Keychain findings and local builds

The first app build could create/read its item without an extra prompt. Ad-hoc updates changed its code identity and prompted again. Using a persistent self-signed certificate supplied a stable designated requirement, but the tested Mac still created **code-hash Keychain partition ACLs**; a certificate alone was insufficient.

The implemented solution is a small fixed signed CredentialStore helper:

- Reuse its binary byte-for-byte across ordinary app updates, preserving its Keychain code hash.
- The helper checks the live parent process's bundle identifier and signing certificate before reading commands.
- The app verifies the helper's identifier and matching certificate before execution.
- Use anonymous process pipes; no token command-line arguments, local HTTP endpoint, daemon or plaintext credential file.
- Restrict operations to this app's named credential records and exit after each request.
- Log out deletes both native authorization and cloud-session items. It cancels in-flight renewal before deletion so a late request cannot silently recreate the connection. Drafts/cache remain on disk; the visible account/library is cleared.

Two changed app test binaries read through the unchanged helper successfully; an unrelated parent was refused. No global Keychain ACL or system/TLS trust was weakened.

Signing/import over an SSH session initially failed with noninteractive security-session errors (including `errSecInternalComponent` / `-26276`). Launching the narrowly scoped importer/signer through LaunchServices in the logged-in graphical session worked. A temporary encrypted P12 and random password file are removed after import; the signing private key stays in login Keychain. This is local signing, not Developer ID signing or notarization.

## Notes documents, folders, drawings and writes

See [protocol.md](protocol.md) for the request and XML details. The important findings are:

- Production Notes host `https://api.samsungcloud.com`, XML change lists and opaque pagination cursors; initial NOTE/FOLDER cursors are Base64 JSON.
- Important headers: bearer Authorization, `x-sn-sdk-ver=5500`, `x-sn-app-ver=4000`, `X-SN-XML-VER=2`, public feature ID `O4vARCbQ3G`. These are protocol versions, not the app's release version.
- Titles come from downloaded documents, not the change-list records. Folder/content-file names have one Base64 UTF-8 layer; observed folder names also carried invisible trailing markers.
- Typed text has nested Base64 UTF-8 runs separated by Samsung style markers. Section lengths use UTF-16 units. Replacing typed text can replace its original text formatting; unrelated opaque objects are retained.
- `compareForDownsync` supplies original document XML, commit/revision and expiring signed attachment URLs. Cache document content/revisions and omit signed URLs from persistent XML.
- Proprietary SPI/page caches are internal resources, not ordinary image/archive attachments. Do not send them to Archive Utility.
- Page-layer stroke objects contain `strokeBinary`. The observed framing began with little-endian words `0xffffffff`, `4`, `4000`; bounded typed frames expose XY/pressure and ARGB/width data. The preview approximates brush effects rather than implementing Samsung's complete canvas.
- Uploads use multipart `noteResource` XML. Fetch the current commit before saving, retain a backup and download after upload to check the title/body. A stale-write test was rejected without changing the isolated test note.
- The revision preflight is not proof of atomic server compare-and-swap. Complete Samsung-device rendering, advanced pen/page effects and full `.sdocx` interoperability remain separate work.

## Mobile clients (1.1)

- The Mac's SDK entry point, encrypted `svcParam`, `ms-app://…` redirect, Notes authorization and Android-profile registration were reused unchanged on iOS and Android. Only the visible device fields differ: model (`iPhone`, `iPad` or Android `Build.MODEL`), name/alias (*Samsung Cloud Notes for iPhone/iPad/Android*), OS version and user agent.
- iOS: `ASWebAuthenticationSession` accepts the `ms-app` callback scheme exactly as on macOS. A native simulator sign-in, registration and library sync succeeded.
- Android: a Custom Tab can return the callback because the app registers an intent filter for the redirect's scheme and host. The registration body keeps the verified `osVersion` 35 / `platformVersion` 6.0.0 profile rather than the device's real SDK level.
- On a fresh Android emulator, the first SDK sign-in page answered **Access denied — unusual activity (400)** before the form. Controlled reloads then showed the normal form for both the Mac-identical and the Android device fields, and the app's own flow succeeded after the browser had visited account.samsung.com once. The denial therefore tracks the browser profile's history (Samsung's risk check), not the payload.
- Foundation's `XMLDocument` is unavailable on iOS. The portable tree preserves attribute order, comments, processing instructions, CDATA and whitespace, and rejects DTDs; its serialization of the self-test fixture is checked against Foundation on macOS.

## Verification boundary and reproducibility

The original native checks loaded 35 records, restored them in cache-only mode, downloaded zero unchanged documents on a warm refresh, decoded five drawing pages/772 strokes and passed isolated Unicode write/readback/conflict checks. These counts describe the test library, not a product limit or synthetic demo.

Relevant code: `Sources/Shared/Authentication.swift`, `Sources/macOS/Credentials.swift`, `Sources/Shared/Cloud.swift`, `Sources/Shared/Cache.swift`, `Sources/Shared/Drawing.swift`, `Sources/macOS/App.swift` and the signing/credential scripts; the Android equivalents live in `android/app/src/main/java/local/samsungcloudnotes/`. Diagnostic flags include `--self-test`, `--verify-native`, `--verify-cache`, `--verify-previews`, `--verify-cloud` and the isolated-note guarded `--test-save`. The sign-out diagnostic verifies local credential removal and restores the existing connection in memory afterward.

Do not publish research databases, traces, DPAPI captures, live connections, signed download URLs, private binary projects, browser callback URLs from active attempts or loose signing keys. Public protocol client IDs above should not be confused with user tokens.

References: [samsung-re-health](https://github.com/charlesbel/samsung-re-health), [sdocx](https://github.com/twangodev/sdocx), [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
