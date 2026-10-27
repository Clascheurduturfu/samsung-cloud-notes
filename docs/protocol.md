# Observed Samsung Notes cloud protocol

Inspected on 2026-10-19 using the installed Windows Samsung Notes **4.3.831.0**. These are interoperability observations, not a Samsung-supported public API contract.

## Transport and account

The observed production base URL is `https://api.samsungcloud.com`. The active Windows client used an opaque bearer session. Its protected account credentials were not copied into source, documentation or application binaries.

Observed request headers include:

| Header | Observed value or purpose |
| --- | --- |
| `Authorization` | Opaque `Bearer …` session; secret |
| `x-sn-sdk-ver` | `5500` |
| `x-sn-app-ver` | `4000` |
| `X-SN-XML-VER` | `2` |
| `X-SN-Feature-ID` | Public client feature identifier `O4vARCbQ3G` |
| `x-sn-model-name` | Device display metadata |

Adding `X-SC-DVC-ID` or `X-SC-DID` to these bearer-authenticated calls was explicitly rejected by Samsung's gateway. Those headers are not a solution to creating an independent device identity.

## Index

- `GET /samsungnotes/v1/notes/changes?lastChangePoint=…`
- `GET /samsungnotes/v1/folder/changes?lastChangePoint=…`

Responses are XML. Note changes contain server/resource identifiers, revision/commit identifiers, timestamps and deletion/lock/encryption flags. Note titles are obtained from the documents, not the change list.

The initial cursor is base64-encoded JSON with `version: 0`, empty `encryptedGuid`, zero timestamps, string versions `"0"`, `purpose: "INITIAL"`, and `type: "NOTE"` or `"FOLDER"`. This initial form was present in the shipped sync library. Subsequent cursors are opaque values returned by Samsung. Continue until `hasNext` is false; do not assume one response includes the full library.

The Windows database initially contained 34 notes, including two in the trash. Direct cloud pagination returned the same 34 non-deleted records, plus historical deletions. One separately identified test note was then created for write validation.

## Document and attachments

- `POST /samsungnotes/v1/notes/{serverId}/compareForDownsync`
- Content type: `application/xml`
- Empty local comparison body: `<note ver="1"/>`

This returned a `CompareNoteView` containing `noteResource`, `downloadUrls`, `commitId` and device metadata. The resource includes the note tree, attributes/title, pages, floating objects, main body text, and content-file references.

Attachment download entries associate a content-file identifier with an HTTPS download URL. Observed URLs used a regional `*.samsungcloud.com` host. Download URLs are account data and must not appear in ordinary logs.

Folder names and content-file names use a single Base64 UTF-8 layer. Actual folder names ended in U+200B; 0.1.2 removes that invisible marker for display. A `0@page_0000000.spi` content file was a proprietary Samsung page cache, not a normal attachment. Internal cache resources remain exportable but are not opened in Archive Utility.

## Read-only drawing preview (0.1.2)

Page layers contain `object type="stroke"` elements with Base64 `strokeBinary` data, independently of the SPI cache. Observed records begin with three little-endian 32-bit words: `0xffffffff`, `4`, `4000`, followed by typed base and ink frames. The small Swift decoder bounds every frame and channel, reads saved XY/pressure channels and initial ARGB/pen-size fields, and leaves original XML untouched. Layout facts were checked directly against the account's cloud records and cross-referenced with [sdocx's format research](https://github.com/twangodev/sdocx/tree/main/docs/reverse-engineering); no upstream source is bundled.

This is an approximate stroke preview, not a complete Samsung canvas renderer. Advanced brush effects, erasers, rotations, floating-image composition and unsupported object types need further work. A real 105-stroke document rendered to an inspected PNG and a PDF with the expected page bounds. The complete active library produced five drawing pages and 772 supported strokes; generated PDF page counts matched.

## Typed text

The object's `text` field is base64-encoded UTF-8. Its decoded contents combine `<?a …?>` style markers with further base64-encoded UTF-8 text runs. Decoding only one base64 layer is insufficient. UTF-16 text length is used in the section metadata.

The client retains the original XML. When editing a supported text object, it replaces that object's styled text, updates its modification/hash fields and the corresponding tree entry, and preserves the remaining resource.

### Text Samsung devices can open

A cloud readback is not enough: Samsung Notes on a phone parses every downloaded note with its S Pen SDK and silently skips notes it cannot parse (its log shows `fail to createLocalNote` and `Spen SDK can't parse a xml note`). Checked against Samsung Notes 4.4.45 on a Galaxy S23+ with `adb logcat` (tags `SENL$SC/...`):

- Every style opened in a `<?a 'key'='value'?>` marker must be closed by a bare `'key'` before the text ends; an open paragraph style fails with "Wrong Annotater Type".
- An object's `timeStamp` is parsed as a 32-bit integer; real notes keep `0`.
- A `spanOrderDataList` must hold at least one `spanOrderData`; an empty list fails to parse. Span order data describes the replaced runs, so the client removes the whole list when it writes plain text.
- Each `noteTree` entry is matched to its element by id + time + hash: `t` must equal the element's `modifiedTime` and `h` its `hash` (the server rejects mismatches with 422 "can not find in tree/resource").
- `NoteResource.createdTime` is in microseconds and `syncModifiedTime` in milliseconds.

Versions before this fix wrote notes that the phone could not open; saving such a note again repairs it.

## Write

- `GET /samsungnotes/v1/notes/{serverId}/info` returns the current revision in an XML attribute.
- `POST /samsungnotes/v1/notes/{serverId}/update` accepts multipart form data with an `application/xml` part named `noteResource`.

The tested upload returned HTTP 201 and a `DefaultView` with resource/revision/timestamp information. A fresh download returned the edited text. The native Mac client also completed this write/readback flow, including accented, Japanese and emoji text.

No delete operation was used. Existing personal notes were not edited by the validation scripts; all writes targeted the separate test note.

## Remaining interoperability work

- Samsung may change its private authentication and document APIs; native sign-in and renewal are described in [authentication](authentication.md).
- Actual Samsung-device rendering of the newly encoded text, separate from a cloud readback.
- Complete handwriting/page rendering and `.sdocx` import/export.
- Server-side atomic conflict guarantees.

The Windows application skipped downloading a change tagged with its own borrowed device identity during the initial Windows-session prototype. Native 0.2.0 sign-in uses a separate Mac installation identity. Cloud readback still does not by itself prove Samsung-device rendering.
