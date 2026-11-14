import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import Security

let appVersion = "1.1.1"
let appShortVersion = appVersion.components(separatedBy: "-")[0]
var transientSession: AccountSession?

enum NotesError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct AccountSession: Codable {
    var authorization: String
    var account: String
    var nativeID: String? = nil
    var expiresAt: Date? = nil
    var importedAt: Date = Date()
    enum CodingKeys: String, CodingKey { case authorization, account, nativeID, expiresAt }
}

enum SessionStore {
    static let service = "local.samsung-cloud-notes.session"
    static func save(_ value: AccountSession) throws {
        guard value.authorization.hasPrefix("Bearer "), value.authorization.count > 30,
              !value.authorization.contains("\n"), !value.authorization.contains("\r") else {
            throw NotesError.message("This connection file does not contain a valid Samsung session.")
        }
        _ = try CredentialVault.perform("save", service: service, data: JSONEncoder().encode(value))
    }
    static func load() throws -> AccountSession {
        guard let data = try CredentialVault.perform("load", service: service) else { throw CredentialError.status(errSecItemNotFound) }
        return try JSONDecoder().decode(AccountSession.self, from: data)
    }
    static func delete() throws { _ = try CredentialVault.perform("delete", service: service) }
}

extension XMLElement {
    var bytes: Data { Data(xmlString(options: []).utf8) }
    func first(_ name: String) -> XMLElement? { elements(forName: name).first }
    func value(_ name: String) -> String { first(name)?.stringValue ?? "" }
    func attr(_ name: String) -> String { attribute(forName: name)?.stringValue ?? "" }
    func set(_ name: String, _ value: String) {
        if let attribute = attribute(forName: name) { attribute.stringValue = value }
        else { addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
}

enum StyledText {
    static let marker = try! NSRegularExpression(pattern: "<\\?.*?\\?>", options: [.dotMatchesLineSeparators])
    static func decode(_ encoded: String) throws -> String {
        if encoded.isEmpty { return "" }
        guard let data = Data(base64Encoded: encoded), let source = String(data: data, encoding: .utf8) else {
            throw NotesError.message("This text uses an unsupported encoding. Its original data has been retained.")
        }
        var output = ""
        var offset = source.startIndex
        for match in marker.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            output += try decodeRun(String(source[offset..<range.lowerBound]))
            offset = range.upperBound
        }
        output += try decodeRun(String(source[offset...]))
        return output
    }
    static func decodeRun(_ value: String) throws -> String {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let compact = value.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact),
              let text = String(data: data, encoding: .utf8) else {
            throw NotesError.message("This text includes an unsupported span. Export the original document to retain it.")
        }
        return text
    }
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    static func encode(_ text: String) -> String {
        let clean = normalized(text)
        guard !clean.isEmpty else { return "" }
        let count = clean.utf16.count
        let lines = clean.components(separatedBy: "\n")
        var payload = "<?a 'span/fontSize'='1,15.0' 'span/foregroundColor'='1,-14342875' 'paragraph/alignment'='0' 'paragraph/parsingState'='false' 'sectionData/sectionData'='\(count)'?>"
        payload += Data(lines[0].utf8).base64EncodedString()
        for line in lines.dropFirst() {
            payload += "<?a 'paragraph/alignment' 'paragraph/parsingState' 'paragraph/alignment'='0' 'paragraph/parsingState'='false'?>"
            payload += Data(("\n" + line).utf8).base64EncodedString()
        }
        payload += "<?a 'span/fontSize' 'span/foregroundColor' 'paragraph/alignment' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>"
        return Data(payload.utf8).base64EncodedString()
    }
    static func encodeTitle(_ text: String) -> String {
        let clean = normalized(text)
        guard !clean.isEmpty else { return "" }
        let lines = clean.components(separatedBy: "\n")
        var payload = "<?a 'paragraph/parsingState'='false'?>" + Data(lines[0].utf8).base64EncodedString()
        for line in lines.dropFirst() {
            payload += "<?a 'paragraph/parsingState' 'paragraph/parsingState'='false'?>" + Data(("\n" + line).utf8).base64EncodedString()
        }
        payload += "<?a 'paragraph/parsingState'?>"
        return Data(payload.utf8).base64EncodedString()
    }
    static func spanOrderData(for text: String) -> [String] {
        let count = normalized(text).utf16.count
        guard count > 0 else { return [] }
        return [
            Data("3,0,\(count),1,15.0".utf8).base64EncodedString(),
            Data("1,0,\(count),1,-14342875".utf8).base64EncodedString()
        ]
    }
}

struct NoteRecord: Identifiable, Codable {
    var id: String
    var resourceID: String
    var commit: String
    var modified: Double
    var locked: Bool
    var encrypted: Bool
    var title: String = "Untitled"
    var snippet: String = ""
    var folder: String = ""
    var trashed: Bool = false
}
struct FolderRecord: Identifiable, Codable { var id: String; var name: String; var parent: String }
struct CloudIndex: Codable { var notes: [NoteRecord]; var folders: [FolderRecord] }
func decodedCloudName(_ value: String) -> String {
    guard let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8),
          !decoded.isEmpty, !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return value }
    return String(String.UnicodeScalarView(decoded.unicodeScalars.filter { $0.value != 0x200b && $0.value != 0xfeff }))
}
struct AssetRecord: Identifiable {
    var id: String; var name: String; var url: URL?
    var fileName: String { name.components(separatedBy: "@").dropFirst().joined(separator: "@").nonEmpty ?? name }
    var isInternal: Bool { ["spi", "spd", "page", "dat"].contains((fileName as NSString).pathExtension.lowercased()) }
}
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

final class CloudDocument {
    let serverID: String
    let xml: XMLDocument
    let resource: XMLElement
    let commit: String
    let bodyObject: XMLElement?
    let titleObject: XMLElement?
    var body: String
    var title: String
    var assets: [AssetRecord] = []
    let original: Data
    let textIssue: String?
    var drawingPages: [DrawingPage] = []
    init(serverID: String, data: Data) throws {
        self.serverID = serverID; self.original = data
        xml = try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement(), root.name == "CompareNoteView",
              let resource = root.first("noteResource") else { throw NotesError.message("Samsung returned an unsupported note document.") }
        self.resource = resource
        commit = root.value("commitId")
        bodyObject = resource.first("bodyText")?.first("object")
        titleObject = resource.first("attributes")?.first("title")?.first("object")
        var issues: [String] = []
        do { body = try StyledText.decode(bodyObject?.value("text") ?? "") }
        catch { body = ""; issues.append(error.localizedDescription) }
        do { title = try StyledText.decode(titleObject?.value("text") ?? "") }
        catch { title = ""; issues.append(error.localizedDescription) }
        textIssue = issues.isEmpty ? nil : issues.joined(separator: " ")
        let contentFiles = resource.first("contentFileList")?.elements(forName: "contentFile") ?? []
        for download in root.first("downloadUrls")?.elements(forName: "downloadUrl") ?? [] {
            let id = download.value("id")
            guard let url = URL(string: download.value("url")), url.scheme == "https",
                  let host = url.host, host == "samsungcloud.com" || host.hasSuffix(".samsungcloud.com") else { continue }
            let file = contentFiles.first(where: { $0.attr("id") == id })
            assets.append(AssetRecord(id: id, name: decodedCloudName(file?.attr("name") ?? id), url: url))
        }
        if root.first("downloadUrls") == nil {
            for file in contentFiles {
                assets.append(AssetRecord(id: file.attr("id"), name: decodedCloudName(file.attr("name")), url: nil))
            }
        }
        drawingPages = (resource.first("pageList")?.elements(forName: "page") ?? []).enumerated().compactMap { index, page in DrawingPage(page, index: index) }
    }
    var bodyNeedsNativeRepair: Bool {
        guard let object = bodyObject else { return false }
        if (Int64(object.attr("timeStamp")) ?? 0) > Int64(Int32.max) { return true }
        if (Int64(resource.first("attributes")?.attr("editTime") ?? "") ?? 0) > Int64(Int32.max) { return true }
        let raw = object.value("text")
        if let data = Data(base64Encoded: raw.filter { !$0.isWhitespace }),
           let decoded = String(data: data, encoding: .utf8),
           decoded.contains("'paragraph/parsingState'='False'") || decoded.contains("'span/fontSize'='1,12'") {
            return true
        }
        return false
    }
    var titleNeedsNativeRepair: Bool {
        guard let object = titleObject else { return false }
        if (Int64(object.attr("timeStamp")) ?? 0) > Int64(Int32.max) { return true }
        let raw = object.value("text")
        if let data = Data(base64Encoded: raw.filter { !$0.isWhitespace }),
           let decoded = String(data: data, encoding: .utf8),
           decoded.contains("span/fontSize") || decoded.contains("sectionData/sectionData") || decoded.contains("'paragraph/parsingState'='False'") {
            return true
        }
        return false
    }
    var needsNativeRepair: Bool { bodyNeedsNativeRepair || titleNeedsNativeRepair }
    func uploadXML(title newTitle: String, body newBody: String, now: Date = Date()) throws -> Data {
        if let textIssue { throw NotesError.message(textIssue) }
        if resource.attr("isEncrypted") == "true" || resource.attr("isLocked") == "true" {
            throw NotesError.message("Locked or encrypted notes cannot be edited by this version.")
        }
        // Android filters the change list using this millisecond timestamp before
        // comparing object hashes. Text readback alone cannot verify native sync.
        let previousSync = Int64(resource.attr("syncModifiedTime")) ?? 0
        let previousEdit = Int64(resource.first("attributes")?.attr("modifiedTime") ?? "") ?? 0
        let editMicros = max(Int64(now.timeIntervalSince1970 * 1_000_000), (previousSync + 1) * 1000, previousEdit + 1)
        let micros = String(editMicros)
        let millis = String(editMicros / 1000)
        if body != newBody || bodyNeedsNativeRepair {
            guard let object = bodyObject,
                  let tree = resource.first("noteTree")?.first("bodyText") else {
                throw NotesError.message("This note has no supported typed-text body. Its drawings are retained in the original document.")
            }
            let text: XMLElement
            if let existing = object.first("text") { text = existing }
            else {
                let created = XMLElement(name: "text")
                object.addChild(created)
                text = created
            }
            text.stringValue = StyledText.encode(newBody)
            let orderData = StyledText.spanOrderData(for: newBody)
            if let existingList = object.first("spanOrderDataList") {
                for child in existingList.elements(forName: "spanOrderData") { child.detach() }
                for val in orderData {
                    let item = XMLElement(name: "spanOrderData")
                    item.set("val", val)
                    existingList.addChild(item)
                }
            } else if !orderData.isEmpty {
                let list = XMLElement(name: "spanOrderDataList")
                for val in orderData {
                    let item = XMLElement(name: "spanOrderData")
                    item.set("val", val)
                    list.addChild(item)
                }
                object.addChild(list)
            }
            if let zeroList = object.first("zeroLengthSpanList") {
                for child in zeroList.elements(forName: "zeroLengthSpan") { child.detach() }
            }
            updateObject(object, tree: tree, micros: micros)
        }
        if title != newTitle || titleNeedsNativeRepair {
            guard let object = titleObject else { throw NotesError.message("This note's title cannot be edited yet.") }
            let encodedTitle = StyledText.encodeTitle(newTitle)
            if let field = object.first("text") {
                if encodedTitle.isEmpty { field.detach() }
                else { field.stringValue = encodedTitle }
            } else if !encodedTitle.isEmpty {
                object.addChild(XMLElement(name: "text", stringValue: encodedTitle))
            }
            for child in object.elements(forName: "spanOrderDataList") { child.detach() }
            for child in object.elements(forName: "zeroLengthSpanList") { child.detach() }
            object.set("modifiedTime", micros)
            object.set("timeStamp", "0")
            object.set("hash", hash(object.bytes))
        }
        resource.set("syncModifiedTime", millis)
        if let attrs = resource.first("attributes") {
            attrs.set("modifiedTime", micros)
            if (Int64(attrs.attr("editTime")) ?? 0) > Int64(Int32.max) || attrs.attr("editTime").isEmpty {
                attrs.set("editTime", "0")
            }
            attrs.set("displayModifiedTime", millis)
        }
        return resource.bytes
    }
    func uploadTextDelta(title: String, body: String, now: Date = Date()) throws -> Data {
        let xml = try XMLDocument(data: uploadXML(title:title,body:body,now:now), options:[.nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement() else { throw NotesError.message("Could not prepare the note update.") }
        // The unchanged page/file objects already exist on the server. Sending
        // them again declares binary multipart uploads (including strokeResource).
        // Keep their complete hash tree so Samsung preserves the existing objects.
        for name in ["pageList", "contentFileList"] { for child in root.elements(forName:name) { child.detach() } }
        return root.bytes
    }
    private func updateObject(_ object: XMLElement, tree: XMLElement, micros: String) {
        object.set("modifiedTime", micros); object.set("timeStamp", "0")
        let digest = hash(object.bytes)
        object.set("hash", digest); tree.set("h", digest); tree.set("t", micros)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class CloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(redirected)
    }
}

final class CloudClient {
    private(set) var account: AccountSession
    private let transport: URLSession
    private let base = URL(string: "https://api.samsungcloud.com")!
    init(account: AccountSession) {
        self.account = account
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.httpCookieStorage = nil
        transport = URLSession(configuration: configuration, delegate: CloudRedirectDelegate(), delegateQueue: nil)
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> Data {
        guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: base), url.host == base.host else { throw NotesError.message("Invalid Samsung Cloud path.") }
        if account.nativeID != nil { account = try await SamsungSignIn.shared.renew(account) }
        for attempt in 0...1 {
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("5500", forHTTPHeaderField: "x-sn-sdk-ver")
        request.setValue("4000", forHTTPHeaderField: "x-sn-app-ver")
        request.setValue("2", forHTTPHeaderField: "X-SN-XML-VER")
        request.setValue("O4vARCbQ3G", forHTTPHeaderField: "X-SN-Feature-ID")
        request.setValue(ClientPlatform.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Data(ClientPlatform.model.utf8).base64EncodedString(), forHTTPHeaderField: "x-sn-model-name")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotesError.message("No response from Samsung Cloud.") }
        if http.statusCode == 401 || http.statusCode == 403 {
            if account.nativeID != nil, attempt == 0 { account = try await SamsungSignIn.shared.renew(account, force: true); continue }
            throw NotesError.message(account.nativeID == nil ? "This imported connection expired. Sign in with Samsung on this device, or import a refreshed Windows connection." : "Samsung rejected the renewed connection. Sign in with Samsung again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            let message = xml?.rootElement()?.value("message") ?? ""
            throw NotesError.message("Samsung Cloud returned \(http.statusCode)\(message.isEmpty ? "" : ": " + message).")
        }
        return data
        }
        throw NotesError.message("Samsung could not renew the Notes connection.")
    }
    static func initialCursor(_ type: String) -> String {
        let value: [String: Any] = ["version": 0, "encryptedGuid": "", "requestTimeStamp": 0,
            "modifiedTime": 0, "appVersion": "0", "sdkVersion": "0", "purpose": "INITIAL", "type": type]
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).base64EncodedString()
    }
    func loadIndex() async throws -> CloudIndex {
        var cursor = Self.initialCursor("NOTE")
        var notes: [String: NoteRecord] = [:]
        var seen = Set<String>()
        var completed = false
        for _ in 0..<10_000 {
            guard seen.insert(cursor).inserted else { throw NotesError.message("Samsung returned a repeated pagination cursor.") }
            let query = URLQueryItem(name: "lastChangePoint", value: cursor)
            var parts = URLComponents(); parts.queryItems = [query]
            let data = try await request("/samsungnotes/v1/notes/changes?" + parts.percentEncodedQuery!)
            let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            guard let root = document.rootElement(), root.name == "NoteChangesView" else { throw NotesError.message("Samsung returned an unexpected note index.") }
            for change in root.elements(forName: "changes") {
                let id = change.value("serverId")
                if change.value("isDeleted") == "true" { notes.removeValue(forKey: id); continue }
                notes[id] = NoteRecord(id: id, resourceID: change.value("resourceId"), commit: change.value("commitId"),
                    modified: Double(change.value("serverModifiedTime")) ?? 0,
                    locked: change.value("isLocked") == "true", encrypted: change.value("isEncrypted") == "true")
            }
            if root.value("hasNext") != "true" { completed = true; break }
            cursor = root.value("lastChangePoint")
            if cursor.isEmpty { throw NotesError.message("Samsung omitted the next pagination cursor.") }
        }
        guard completed else { throw NotesError.message("The note index exceeded the pagination limit.") }
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "lastChangePoint", value: Self.initialCursor("FOLDER"))]
        let folderData = try await request("/samsungnotes/v1/folder/changes?" + components.percentEncodedQuery!)
        let folderXML = try XMLDocument(data: folderData, options: [.nodeLoadExternalEntitiesNever])
        var folders: [FolderRecord] = []
        for node in folderXML.rootElement()?.first("folderResource")?.first("nodeList")?.elements(forName: "node") ?? [] {
            let state = node.value("state")
            if node.attr("type") == "folder", state == "normal" {
                folders.append(FolderRecord(id: node.attr("id"), name: decodedCloudName(node.value("name")), parent: node.value("parentFolderNodeId")))
            } else if node.attr("type") == "note" {
                if let id = notes.values.first(where: { $0.resourceID == node.attr("id") })?.id {
                    notes[id]?.folder = node.value("parentFolderNodeId")
                    notes[id]?.trashed = state == "trashed"
                    if state == "deleted" { notes.removeValue(forKey: id) }
                }
            }
        }
        return CloudIndex(notes: notes.values.sorted { $0.modified > $1.modified }, folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    func download(_ id: String) async throws -> CloudDocument {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NotesError.message("Invalid note identifier.") }
        let data = try await request("/samsungnotes/v1/notes/\(id)/compareForDownsync", method: "POST", body: Data("<note ver=\"1\"/>".utf8), contentType: "application/xml")
        return try CloudDocument(serverID: id, data: data)
    }
    func currentCommit(_ id: String) async throws -> String {
        let data = try await request("/samsungnotes/v1/notes/\(id)/info")
        guard let value = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]).rootElement()?.attr("commitId"), !value.isEmpty else { throw NotesError.message("Samsung omitted the current revision.") }
        return value
    }
    func save(_ document: CloudDocument, title: String, body: String) async throws -> CloudDocument {
        let remoteCommit = try await currentCommit(document.serverID)
        guard remoteCommit == document.commit else { throw NotesError.message("This note changed on another device. Your draft is saved locally; reload the cloud copy before saving again.") }
        try LocalStore.backup(document)
        let previousSync = Int64(document.resource.attr("syncModifiedTime")) ?? 0
        let xml = try document.uploadTextDelta(title: title, body: body)
        let boundary = "SamsungNotesMac-" + UUID().uuidString
        var payload = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"noteResource\"\r\nContent-Type: application/xml\r\n\r\n".utf8)
        payload.append(xml); payload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        _ = try await request("/samsungnotes/v1/notes/\(document.serverID)/update", method: "POST", body: payload, contentType: "multipart/form-data; boundary=\(boundary)")
        let fresh = try await download(document.serverID)
        guard fresh.body == body, fresh.title == title else { throw NotesError.message("Samsung accepted the upload, but its readback differs from the draft. The local draft and backup are retained.") }
        guard let nativeSync = Int64(fresh.resource.attr("syncModifiedTime")), nativeSync > previousSync else {
            throw NotesError.message("Samsung returned the saved text without advancing its phone sync timestamp. Your local draft and backup are retained; try saving again.")
        }
        return fresh
    }
    func downloadAsset(_ asset: AssetRecord) async throws -> Data {
        guard let url = asset.url else { throw NotesError.message("Reload the note to retrieve this attachment from Samsung Cloud.") }
        if account.nativeID != nil { account = try await SamsungSignIn.shared.renew(account) }
        var request = URLRequest(url: url)
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NotesError.message("The attachment download failed. Reload the note to refresh its download URL.") }
        return data
    }
}

enum LocalStore {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SamsungCloudNotes", isDirectory: true)
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func backup(_ document: CloudDocument) throws {
        let destination = try directory("Backups").appendingPathComponent("\(document.serverID)-\(Int(Date().timeIntervalSince1970 * 1000)).xml")
        try document.original.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    static func writeDraft(id: String, title: String, body: String, commit: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["title": title, "body": body, "commit": commit])
        let url = try directory("Drafts").appendingPathComponent(id + ".json")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func archiveDraft(id: String) throws {
        let source = try directory("Drafts").appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        let target = try directory("DraftHistory").appendingPathComponent("\(id)-\(Int(Date().timeIntervalSince1970 * 1000)).json")
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
