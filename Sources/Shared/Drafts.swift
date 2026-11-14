import Foundation

struct NoteDraft: Codable, Equatable {
    var title: String
    var body: String
    var commit: String
}

/// Only unsaved edits belong in Drafts. Clean cloud copies live in NoteCache.
struct NoteDraftStore {
    var root: URL = LocalStore.root
    private func directory(_ name: String) throws -> URL {
        let value = root.appendingPathComponent(name,isDirectory:true)
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return value
    }
    func file(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw NotesError.message("Invalid local note identifier.") }
        return try directory("Drafts").appendingPathComponent(id+".json")
    }
    func read(_ id: String) throws -> NoteDraft? {
        let url = try file(id)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        return try JSONDecoder().decode(NoteDraft.self,from:Data(contentsOf:url))
    }
    func write(_ draft: NoteDraft, id: String) throws {
        let url = try file(id)
        try JSONEncoder().encode(draft).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func archive(_ bytes: Data, id: String) throws {
        let url = try directory("DraftHistory").appendingPathComponent(id+"-"+UUID().uuidString+".json")
        try bytes.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func discard(_ id: String, current: NoteDraft? = nil) throws {
        let url = try file(id)
        let existing = FileManager.default.fileExists(atPath:url.path) ? try Data(contentsOf:url) : nil
        if let existing { try archive(existing,id:id) }
        if let current, existing.flatMap({ try? JSONDecoder().decode(NoteDraft.self,from:$0) }) != current {
            try archive(JSONEncoder().encode(current),id:id)
        }
        // Do not remove the active file unless every recovery copy succeeded.
        if existing != nil { try FileManager.default.removeItem(at:url) }
    }
    func removeIfMatches(_ id: String, draft: NoteDraft?) throws {
        guard let draft, try read(id) == draft else { return }
        try FileManager.default.removeItem(at:file(id))
    }
}
