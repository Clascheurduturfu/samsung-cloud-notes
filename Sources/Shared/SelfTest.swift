import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CoreGraphics
import CryptoKit

/// Offline checks shared by every Apple client. No network, Keychain or account access.
enum SelfTest {
    static func run() throws {
        guard SamsungAuthCrypto.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" else { throw NotesError.message("PKCE reference vector failed.") }
        let callbackKey = Data("0123456789abcdef".utf8)
        let encryptedCallback = try SamsungAuthCrypto.aes(Data("synthetic-callback".utf8), key: callbackKey, encrypt: true, ecb: true).map { String(format: "%02x", $0) }.joined()
        guard try SamsungAuthCrypto.callback(encryptedCallback, key: "0123456789abcdef-extra") == "synthetic-callback" else { throw NotesError.message("Samsung callback decryption failed.") }
        do { _ = try SamsungAuthCrypto.callback("not-hex", key: "test"); throw NotesError.message("Malformed callback was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Malformed callback was accepted." { throw error } }
        let cases = ["", "hello", "café — 日本語 🚀", "first\nsecond\n", "<&> \"quotes\""]
        for value in cases {
            guard try StyledText.decode(StyledText.encode(value)) == value,
                  try StyledText.decode(StyledText.encodeTitle(value)) == value.replacingOccurrences(of: "\r\n", with: "\n") else {
                throw NotesError.message("Text round-trip mismatch.")
            }
        }
        guard StyledText.encode("") == "", StyledText.encodeTitle("") == "" else {
            throw NotesError.message("Empty styled text was not empty.")
        }
        if let multiData = Data(base64Encoded: StyledText.encode("first\nsecond")),
           let multiDecoded = String(data: multiData, encoding: .utf8) {
            func occurrences(_ needle: String, in haystack: String) -> Int {
                haystack.components(separatedBy: needle).count - 1
            }
            guard multiDecoded.contains("'span/fontSize'='1,15.0'"),
                  multiDecoded.contains("'span/foregroundColor'='1,-14342875'"),
                  occurrences("'paragraph/alignment'='0'", in: multiDecoded) == 2,
                  occurrences("'paragraph/alignment' ", in: multiDecoded) == 2,
                  occurrences("'paragraph/parsingState'='false'", in: multiDecoded) == 2,
                  occurrences("'paragraph/parsingState' ", in: multiDecoded) == 2 else {
                throw NotesError.message("Styled body paragraph/span annotations mismatch.")
            }
        } else { throw NotesError.message("Encoded styled body was not base64 UTF-8.") }
        if let titleData = Data(base64Encoded: StyledText.encodeTitle("Title")),
           let titleDecoded = String(data: titleData, encoding: .utf8) {
            guard titleDecoded.contains("'paragraph/parsingState'='false'"),
                  !titleDecoded.contains("span/fontSize"),
                  !titleDecoded.contains("sectionData/sectionData") else {
                throw NotesError.message("Styled title included unsupported span or section tags.")
            }
        } else { throw NotesError.message("Encoded styled title was not base64 UTF-8.") }
        guard decodedCloudName(Data("Math notes\u{200b}".utf8).base64EncodedString()) == "Math notes", decodedCloudName(Data("Math notes 📒".utf8).base64EncodedString()) == "Math notes 📒", decodedCloudName("My notes") == "My notes" else { throw NotesError.message("Folder name decoding failed.") }
        let inkFixture = Data(base64Encoded: "/////wQAAACgDwAADQAAAAAADQAAAAEIAEoAAAABAEIAAAABAAEMAgAAAAAAAAAkQAAAAAAAADRAAAAAAAAAPkAAAAAAAABEQAAAAD8AAEA/AAAAAAoAAAACAFY0Ev8AAEBA")!
        let ink = try InkStroke(inkFixture)
        guard ink.points.count == 2, ink.points[1] == CGPoint(x: 30, y: 40), ink.color == 0xff123456 else { throw NotesError.message("Drawing coordinates or color mismatch.") }
        do { _ = try InkStroke(inkFixture.prefix(25)); throw NotesError.message("Truncated drawing was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Truncated drawing was accepted." { throw error } }
        let mixed = "<?a 'span/bold'='1,True'?>" + Data("one".utf8).base64EncodedString() + "<?a 'span/bold'?>" + Data("\ntwo".utf8).base64EncodedString()
        guard try StyledText.decode(Data(mixed.utf8).base64EncodedString()) == "one\ntwo" else { throw NotesError.message("Styled spans mismatch.") }
        let cursor = Data(base64Encoded: CloudClient.initialCursor("NOTE"))!
        guard let initial = try JSONSerialization.jsonObject(with: cursor) as? [String: Any], initial["purpose"] as? String == "INITIAL" else { throw NotesError.message("Invalid initial cursor.") }
        let fixtureKey = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!
        let fixtureSealed = Data(base64Encoded: "AAECAwQFBgcICQoLPCC3brGNrWnkO/b/2IYWT7n0xVGRCToOGBSc62kBZcZoc4OfwK98/RfQFoLmqk5Rli0V/z/0j/he9El2bY2BzMoegBOrpVMTeXbXPAnzebjVhAMKnKbdV6pdmQ==")!
        let fixturePlain = try AES.GCM.open(AES.GCM.SealedBox(combined: fixtureSealed), using: SymmetricKey(data: fixtureKey))
        let session = try JSONDecoder().decode(AccountSession.self, from: fixturePlain)
        guard session.account == "Fixture", session.authorization == "Bearer synthetic-connection-fixture" else { throw NotesError.message("Windows connection decryption mismatch.") }
        let fixtureXML = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\" unknownField=\"retain\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><spanOrderDataList><spanOrderData val=\"stale\"/></spanOrderDataList><zeroLengthSpanList><zeroLengthSpan val=\"stale-zero\"/></zeroLengthSpanList><text>\(StyledText.encode("Before"))</text></object></bodyText><pageList><page id=\"page\"><opaqueDrawing value=\"preserve\"/></page></pageList><contentFileList><contentFile id=\"asset\" hash=\"original\"/></contentFileList></noteResource><commitId>fixture-revision</commitId><downloadUrls/></CompareNoteView>"
        // The portable DOM must round-trip the fixture exactly as the shared code sees it.
        let portable = try PortableXMLDocument(data: Data(fixtureXML.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard try PortableXMLDocument(data: Data(portable.xmlString.utf8)).xmlString == portable.xmlString,
              portable.rootElement()?.first("noteResource")?.first("bodyText")?.first("object")?.value("text") == StyledText.encode("Before"),
              try portable.nodes(forXPath: "/CompareNoteView/noteResource/pageList/page/opaqueDrawing[@value='preserve']").count == 1,
              try portable.rootElement()?.nodes(forXPath: ".//contentFile").count == 1 else { throw NotesError.message("Portable XML round-trip failed.") }
        let escaped = try PortableXMLDocument(data: Data("<?xml version=\"1.0\"?><!-- c --><a x='1 &amp; &quot;2&quot;' y=\"&#x1F680;\"><b/>t&lt;&#233;<![CDATA[<raw>]]></a>".utf8))
        guard escaped.rootElement()?.attr("x") == "1 & \"2\"", escaped.rootElement()?.attr("y") == "🚀", escaped.rootElement()?.stringValue == "t<é<raw>",
              escaped.xmlString == "<?xml version=\"1.0\"?><!-- c --><a x=\"1 &amp; &quot;2&quot;\" y=\"🚀\"><b/>t&lt;é<![CDATA[<raw>]]></a>" else { throw NotesError.message("Portable XML escaping failed.") }
        for invalid in ["<a><b></a>", "<!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>", "<a/><b/>", "<a x='1' x='2'/>"] {
            guard (try? PortableXMLDocument(data: Data(invalid.utf8))) == nil else { throw NotesError.message("Portable XML accepted invalid input.") }
        }
        #if os(macOS)
        let foundation = try Foundation.XMLDocument(data: Data(portable.xmlString.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard foundation.rootElement()?.xmlString(options: []) == portable.rootElement()?.xmlString() else { throw NotesError.message("Portable XML differs from Foundation XML.") }
        #endif
        let fixture = try CloudDocument(serverID: "fixture", data: Data(fixtureXML.utf8))
        let cacheTestRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SamsungCloudNotes-CacheTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheTestRoot) }
        let cache = try NoteCache(session: session, base: cacheTestRoot)
        var record = NoteRecord(id: "fixture", resourceID: "r", commit: "revision-1", modified: 0, locked: false, encrypted: false)
        try cache.save(fixture, revision: record.commit)
        try cache.saveIndex(CloudIndex(notes: [record], folders: []))
        let reopened = try NoteCache(session: session, base: cacheTestRoot)
        guard reopened.snapshot()?.index.notes.count == 1, reopened.document(record)?.body == "Before" else { throw NotesError.message("Cache did not survive reopening.") }
        record.commit = "revision-2"
        guard reopened.document(record) == nil else { throw NotesError.message("A stale cached revision was accepted.") }
        record.commit = "revision-1"; record.locked = true
        guard reopened.document(record) == nil else { throw NotesError.message("A locked note was restored from cache.") }
        let nativeOne = AccountSession(authorization: "Bearer synthetic-native-first", account: "Fixture", nativeID: "native:fixture:mac")
        let nativeCache = try NoteCache(session: nativeOne, base: cacheTestRoot)
        try nativeCache.saveIndex(CloudIndex(notes: [record], folders: []))
        let nativeTwo = AccountSession(authorization: "Bearer synthetic-native-renewed", account: "Fixture", nativeID: "native:fixture:mac")
        guard try NoteCache(session: nativeTwo, base: cacheTestRoot).snapshot()?.index.notes.count == 1 else { throw NotesError.message("Native token renewal lost its cache.") }
        let differentNative = AccountSession(authorization: "Bearer synthetic-other-account", account: "Fixture", nativeID: "native:other:mac")
        guard try NoteCache(session: differentNative, base: cacheTestRoot).snapshot() == nil else { throw NotesError.message("Native cache leaked between accounts.") }
        let other = try NoteCache(session: AccountSession(authorization: "Bearer different-synthetic-session", account: session.account), base: cacheTestRoot)
        guard other.snapshot() == nil else { throw NotesError.message("Cache leaked between sessions with identical labels.") }
        try cache.saveAsset(Data("offline attachment".utf8), id: "asset", revision: "one")
        guard reopened.asset(id: "asset", revision: "one") == Data("offline attachment".utf8), reopened.asset(id: "asset", revision: "two") == nil else { throw NotesError.message("Attachment cache revision check failed.") }
        try reopened.prune([])
        record.locked = false
        guard reopened.document(record) == nil else { throw NotesError.message("Removed note was retained in cache.") }
        let newBody = "After 日本語 🚀"
        let updated = try XMLDocument(data: fixture.uploadXML(title: "Test title", body: newBody))
        let updatedBodyObj = updated.rootElement()?.first("bodyText")?.first("object")
        let updatedOrders = updatedBodyObj?.first("spanOrderDataList")?.elements(forName: "spanOrderData").map {
            Data(base64Encoded: $0.attr("val")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } ?? []
        let updatedZeros = updatedBodyObj?.first("zeroLengthSpanList")?.elements(forName: "zeroLengthSpan") ?? []
        guard updated.rootElement()?.attr("unknownField") == "retain",
              updated.rootElement()?.first("attributes")?.attr("editTime") == "0",
              updatedBodyObj?.attr("timeStamp") == "0",
              updatedOrders == ["3,0,\(newBody.utf16.count),1,15.0", "1,0,\(newBody.utf16.count),1,-14342875"],
              updatedZeros.isEmpty,
              updated.rootElement()?.first("attributes")?.first("title")?.first("object")?.value("text") == StyledText.encodeTitle("Test title"),
              try updated.nodes(forXPath: "/noteResource/pageList/page/opaqueDrawing[@value='preserve']").count == 1,
              try updated.nodes(forXPath: "/noteResource/contentFileList/contentFile[@hash='original']").count == 1 else {
            throw NotesError.message("Updated XML span order, title, drawing, or attachment metadata failed verification.")
        }
        let legacyBodyPayload = Data(("<?a 'paragraph/alignment'='0' 'paragraph/parsingState'='False' 'span/fontSize'='1,12' 'span/foregroundColor'='1,-14342875' 'sectionData/sectionData'='6'?>" + Data("Legacy".utf8).base64EncodedString() + "<?a 'span/foregroundColor' 'span/fontSize' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>").utf8).base64EncodedString()
        let legacyXML = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes editTime=\"1794667044333760\"><title><object><text>\(legacyBodyPayload)</text></object></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\" timeStamp=\"1794667044333760\"><spanOrderDataList><spanOrderData val=\"stale\"/></spanOrderDataList><text>\(legacyBodyPayload)</text></object></bodyText></noteResource><commitId>legacy-rev</commitId></CompareNoteView>"
        let legacyDoc = try CloudDocument(serverID: "legacy", data: Data(legacyXML.utf8))
        guard legacyDoc.needsNativeRepair else { throw NotesError.message("Legacy Mac XML was not flagged for native repair.") }
        let fixedResourceXML = try legacyDoc.uploadXML(title: legacyDoc.title, body: legacyDoc.body)
        let wrappedFixed = "<CompareNoteView>" + String(decoding: fixedResourceXML, as: UTF8.self) + "<commitId>fixed-rev</commitId></CompareNoteView>"
        let fixedDoc = try CloudDocument(serverID: "legacy", data: Data(wrappedFixed.utf8))
        guard !fixedDoc.needsNativeRepair,
              fixedDoc.body == "Legacy", fixedDoc.title == "Legacy",
              fixedDoc.bodyObject?.attr("timeStamp") == "0",
              fixedDoc.resource.first("attributes")?.attr("editTime") == "0" else {
            throw NotesError.message("Legacy Mac XML repair failed.")
        }
        let syncFixture = try CloudDocument(serverID: "sync-fixture", data: Data(fixtureXML.utf8))
        syncFixture.resource.set("syncModifiedTime", "1800000000000")
        let saved = try XMLDocument(data: syncFixture.uploadXML(title: "Phone sync", body: "New body", now: Date(timeIntervalSince1970: 1_700_000_000))).rootElement()!
        guard saved.attr("syncModifiedTime") == "1800000000001",
              saved.first("attributes")?.attr("displayModifiedTime") == "1800000000001",
              saved.first("attributes")?.attr("modifiedTime") == "1800000000001000",
              saved.first("bodyText")?.first("object")?.attr("modifiedTime") == "1800000000001000",
              saved.first("noteTree")?.first("bodyText")?.attr("t") == "1800000000001000" else {
            throw NotesError.message("Phone sync timestamp failed to advance consistently across a backwards clock.")
        }
        let repaired = try XMLDocument(data: syncFixture.uploadXML(title: "Phone sync", body: "New body", now: Date(timeIntervalSince1970: 1_700_000_000))).rootElement()!
        guard repaired.attr("syncModifiedTime") == "1800000000002" else { throw NotesError.message("Repeated saves reused the phone sync timestamp.") }
        let deltaFixture = try CloudDocument(serverID:"delta-fixture",data:Data(fixtureXML.utf8))
        let delta = try XMLDocument(data:deltaFixture.uploadTextDelta(title:"Changed",body:"New text")).rootElement()!
        guard delta.first("pageList") == nil, delta.first("contentFileList") == nil,
              delta.first("noteTree") != nil,
              try StyledText.decode(delta.first("bodyText")?.first("object")?.value("text") ?? "") == "New text",
              deltaFixture.resource.first("pageList")?.first("page")?.first("opaqueDrawing")?.attr("value") == "preserve" else {
            throw NotesError.message("Text delta declared unchanged binary uploads or lost the original drawing data.")
        }
    }
}
