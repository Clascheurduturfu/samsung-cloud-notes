import Foundation
import AppKit
import Security
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Terminal access to the signed app. It runs inside the app executable so the
/// credential helper accepts it exactly like the window app; `scnotes` is a
/// small wrapper installed by `install`.
enum CommandLineTool {
    static let wrapperName = "scnotes"
    static let usage = """
    Samsung Cloud Notes \(appVersion) command line

    Usage: scnotes <command> [options]

    Library
      status                         Account, cache and version information
      sync                           Download changed notes into the local cache
      list [--folder NAME] [--trash] [--limit N]
                                     List notes, newest first
      folders                        List folders
      search QUERY                   Search titles and full typed text
      show NOTE [--xml]              Print a note's title and text (or original XML)

    Changes
      edit NOTE [--title TEXT] [--body TEXT | --body-file PATH|-] [--discard-draft]
                                     Replace title and/or typed text, then save to Samsung Cloud
      export NOTE DIRECTORY          Write NOTE.samsungnote (original XML, text, attachments)
      drawing NOTE OUTPUT.pdf        Write the approximate handwriting preview

    Account
      login                          Open the app to sign in with Samsung
      logout                         Remove the saved connection (cache and drafts remain)
      install [DIRECTORY]            Install the scnotes wrapper (default ~/.local/bin)

    Common options
      --json       Machine-readable output (status, list, folders, search, show)
      --offline    Use only the local cache; never contact Samsung

    NOTE is a note ID, a unique ID prefix, or an exact title.
    """

    struct Failure: LocalizedError {
        var message: String; var code: Int32 = 1
        var errorDescription: String? { message }
    }
    struct Options {
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        func value(_ name: String) -> String? { values[name] }
        var json: Bool { flags.contains("json") }
        var offline: Bool { flags.contains("offline") }
    }
    static let valueOptions: Set<String> = ["folder", "limit", "title", "body", "body-file"]
    static let flagOptions: Set<String> = ["json", "offline", "trash", "xml", "discard-draft", "help"]

    static func run(_ arguments: [String]) -> Never {
        guard let command = arguments.first, !["help", "-h", "--help"].contains(command) else { print(usage); exit(0) }
        if command == "version" || command == "--version" { print(appVersion); exit(0) }
        let options: Options
        do { options = try parse(Array(arguments.dropFirst())) }
        catch { fail(error) }
        if options.flags.contains("help") { print(usage); exit(0) }
        Task { @MainActor in
            do {
                try await perform(command, options)
                exit(0)
            } catch { fail(error) }
        }
        RunLoop.main.run()
        exit(0)
    }
    static func fail(_ error: Error) -> Never {
        fputs("scnotes: \(error.localizedDescription)\n", stderr)
        exit((error as? Failure)?.code ?? 1)
    }
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(); var index = 0
        while index < arguments.count {
            let argument = arguments[index]; index += 1
            guard argument.hasPrefix("--"), argument.count > 2 else { options.positional.append(argument); continue }
            var name = String(argument.dropFirst(2)); var inline: String?
            if let equals = name.firstIndex(of: "=") { inline = String(name[name.index(after: equals)...]); name = String(name[..<equals]) }
            if valueOptions.contains(name) {
                if let inline { options.values[name] = inline; continue }
                guard index < arguments.count else { throw Failure(message: "--\(name) needs a value.", code: 2) }
                options.values[name] = arguments[index]; index += 1
            } else if flagOptions.contains(name), inline == nil { options.flags.insert(name) }
            else { throw Failure(message: "Unknown option --\(name). Run scnotes help.", code: 2) }
        }
        return options
    }

    @MainActor static func perform(_ command: String, _ options: Options) async throws {
        func arguments(_ count: Int, _ names: String) throws {
            guard options.positional.count == count else { throw Failure(message: "Usage: scnotes \(command) \(names)", code: 2) }
        }
        switch command {
        case "status": try arguments(0, ""); try await status(options)
        case "sync":
            try arguments(0, "")
            let library = try await Library.load(offline: false, strict: true)
            print("\(library.index.notes.filter { !$0.trashed }.count) notes, \(library.index.folders.count) folders · downloaded \(library.downloaded) changed or missing documents.")
        case "list": try arguments(0, "[--folder NAME] [--trash]"); try await list(options)
        case "folders":
            try arguments(0, "")
            let library = try await Library.load(offline: options.offline)
            if options.json { try printJSON(library.index.folders.map { ["id": $0.id, "name": $0.name, "parent": $0.parent] }) }
            else { for folder in library.index.folders { print("\(folder.id)\t\(folder.name)") } }
        case "search": try arguments(1, "QUERY"); try await search(options.positional[0], options)
        case "show": try arguments(1, "NOTE [--xml]"); try await show(options.positional[0], options)
        case "edit": try arguments(1, "NOTE [--title TEXT] [--body TEXT | --body-file PATH|-]"); try await edit(options.positional[0], options)
        case "export": try arguments(2, "NOTE DIRECTORY"); try await export(options.positional[0], to: options.positional[1], options)
        case "drawing": try arguments(2, "NOTE OUTPUT.pdf"); try await drawing(options.positional[0], to: options.positional[1], options)
        case "login":
            try arguments(0, "")
            guard let app = appBundle else { throw Failure(message: "Run scnotes from an installed Samsung Cloud Notes.app.") }
            NSWorkspace.shared.open(app)
            print("Opened Samsung Cloud Notes. Choose Sign in with Samsung there, then rerun scnotes.")
        case "logout":
            try arguments(0, "")
            try SamsungSignIn.shared.signOut()
            print("Removed the saved Samsung connection from Keychain. Cache and drafts remain.")
        case "install":
            guard options.positional.count <= 1 else { throw Failure(message: "Usage: scnotes install [DIRECTORY]", code: 2) }
            print(try install(into: options.positional.first))
        default: throw Failure(message: "Unknown command \(command). Run scnotes help.", code: 2)
        }
    }

    // MARK: Library access

    /// The account's index and documents, refreshed from Samsung unless offline.
    /// Unchanged revisions come from the same cache the window app uses.
    @MainActor struct Library {
        var client: CloudClient
        var cache: NoteCache
        var index: CloudIndex
        var documents: [String: CloudDocument] = [:]
        var downloaded = 0
        var offline: Bool
        static func load(offline: Bool, strict: Bool = false) async throws -> Library {
            let session: AccountSession
            do { session = try SessionStore.load() }
            catch CredentialError.status(errSecItemNotFound) { throw Failure(message: "Not signed in. Run scnotes login to sign in with the app.") }
            var library = Library(client: CloudClient(account: session), cache: try NoteCache(session: session), index: CloudIndex(notes: [], folders: []), offline: offline)
            if !offline {
                do { try await library.refresh(); return library }
                catch {
                    if strict || library.cache.snapshot() == nil { throw error }
                    fputs("scnotes: offline, using the cached library (\(error.localizedDescription))\n", stderr)
                    library.offline = true
                }
            }
            guard let snapshot = library.cache.snapshot() else { throw Failure(message: "No cached library yet. Run scnotes sync while online.") }
            library.index = snapshot.index
            for record in library.index.notes { if let document = library.cache.document(record) { library.documents[record.id] = document } }
            return library
        }
        mutating func refresh() async throws {
            index = try await client.loadIndex()
            var failures = 0
            for position in index.notes.indices {
                let record = index.notes[position]
                if record.locked || record.encrypted { continue }
                var document = cache.document(record)
                if document == nil {
                    do {
                        let fresh = try await client.download(record.id)
                        try cache.save(fresh, revision: record.commit)
                        document = fresh; downloaded += 1
                    } catch { failures += 1 }
                }
                if let document { documents[record.id] = document; index.notes[position].describe(document) }
            }
            try cache.prune(index.notes)
            try cache.saveIndex(index)
            if failures > 0 { fputs("scnotes: \(failures) notes could not be downloaded.\n", stderr) }
        }
        func folderName(_ id: String) -> String { index.folders.first { $0.id == id }?.name ?? "" }
        func resolve(_ query: String) throws -> NoteRecord {
            let notes = index.notes
            if let exact = notes.first(where: { $0.id == query }) { return exact }
            let byPrefix = query.count >= 4 ? notes.filter { $0.id.hasPrefix(query) } : []
            if byPrefix.count == 1 { return byPrefix[0] }
            let byTitle = notes.filter { $0.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            if byTitle.count == 1 { return byTitle[0] }
            let candidates = byPrefix.count > 1 ? byPrefix : byTitle
            if candidates.count > 1 {
                throw Failure(message: "\"\(query)\" matches \(candidates.count) notes:\n" + candidates.prefix(10).map { "  \($0.id)\t\($0.title)" }.joined(separator: "\n"))
            }
            throw Failure(message: "No note matches \"\(query)\". Use scnotes list or scnotes search.")
        }
        /// A document with current signed attachment URLs where possible.
        func document(_ record: NoteRecord, fresh: Bool) async throws -> CloudDocument {
            if record.locked || record.encrypted { throw Failure(message: "Locked or encrypted notes are not readable by this version.") }
            if fresh && !offline { return try await client.download(record.id) }
            if let document = documents[record.id] { return document }
            if offline { throw Failure(message: "This note is not in the local cache. Run scnotes sync while online.") }
            return try await client.download(record.id)
        }
    }

    // MARK: Commands

    @MainActor static func status(_ options: Options) async throws {
        var info: [String: Any] = ["version": appVersion]
        do {
            let session = try SessionStore.load()
            info["account"] = session.account
            info["connection"] = session.nativeID == nil ? "imported Windows connection" : "native sign-in"
            if let snapshot = try NoteCache(session: session).snapshot() {
                info["cachedNotes"] = snapshot.index.notes.filter { !$0.trashed }.count
                info["lastSync"] = ISO8601DateFormatter().string(from: snapshot.updated)
            }
        } catch CredentialError.status(errSecItemNotFound) { info["account"] = NSNull() }
        info["dataDirectory"] = LocalStore.root.path
        if options.json { try printJSON(info); return }
        print("Samsung Cloud Notes \(appVersion)")
        print("Account:   \((info["account"] as? String) ?? "not signed in (run scnotes login)")")
        if let connection = info["connection"] { print("Connection: \(connection)") }
        if let count = info["cachedNotes"], let sync = info["lastSync"] { print("Cache:     \(count) notes, last synced \(sync)") }
        print("Data:      \(LocalStore.root.path)")
    }

    @MainActor static func list(_ options: Options) async throws {
        let library = try await Library.load(offline: options.offline)
        var notes = library.index.notes.filter { options.flags.contains("trash") ? $0.trashed : !$0.trashed }
        if let folder = options.value("folder") {
            let matches = library.index.folders.filter { $0.id == folder || $0.name.compare(folder, options: .caseInsensitive) == .orderedSame }
            guard let target = matches.first else { throw Failure(message: "No folder named \"\(folder)\". Run scnotes folders.") }
            notes = notes.filter { $0.folder == target.id }
        }
        if let limit = options.value("limit") {
            guard let count = Int(limit), count > 0 else { throw Failure(message: "--limit needs a positive number.", code: 2) }
            notes = Array(notes.prefix(count))
        }
        try output(notes, library: library, options)
    }

    @MainActor static func search(_ query: String, _ options: Options) async throws {
        let library = try await Library.load(offline: options.offline)
        let notes = library.index.notes.filter { record in
            guard !record.trashed else { return false }
            let text = record.title + "\n" + (library.documents[record.id].map { $0.title + "\n" + $0.body } ?? record.snippet)
            return text.localizedCaseInsensitiveContains(query)
        }
        try output(notes, library: library, options)
    }

    @MainActor static func output(_ notes: [NoteRecord], library: Library, _ options: Options) throws {
        if options.json { try printJSON(notes.map { describe($0, library: library) }); return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for note in notes {
            let date = formatter.string(from: Date(timeIntervalSince1970: note.modified / 1000))
            let folder = library.folderName(note.folder)
            print("\(note.id)\t\(date)\t\(note.locked || note.encrypted ? "🔒 " : "")\(note.title)\(folder.isEmpty ? "" : "\t[\(folder)]")")
        }
        if notes.isEmpty && !options.json { fputs("No notes.\n", stderr) }
    }

    @MainActor static func describe(_ note: NoteRecord, library: Library) -> [String: Any] {
        ["id": note.id, "title": note.title, "snippet": note.snippet, "folderId": note.folder, "folder": library.folderName(note.folder),
         "modified": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: note.modified / 1000)),
         "revision": note.commit, "trashed": note.trashed, "locked": note.locked || note.encrypted]
    }

    @MainActor static func show(_ query: String, _ options: Options) async throws {
        let library = try await Library.load(offline: options.offline)
        let record = try library.resolve(query)
        let document = try await library.document(record, fresh: false)
        if options.flags.contains("xml") { FileHandle.standardOutput.write(document.original); return }
        if options.json {
            var value = describe(record, library: library)
            value["title"] = document.title; value["body"] = document.body
            value["attachments"] = document.assets.filter { !$0.isInternal }.map { ["id": $0.id, "name": $0.fileName] }
            value["drawingPages"] = document.drawingPages.count
            value["editable"] = editIssue(document) == nil
            if let issue = document.textIssue { value["textIssue"] = issue }
            try printJSON(value); return
        }
        print(document.title.isEmpty ? record.title : document.title)
        print(String(repeating: "─", count: 40))
        print(document.body)
        let attachments = document.assets.filter { !$0.isInternal }
        if !attachments.isEmpty || !document.drawingPages.isEmpty {
            print(String(repeating: "─", count: 40))
            if !attachments.isEmpty { print("Attachments: " + attachments.map(\.fileName).joined(separator: ", ")) }
            if !document.drawingPages.isEmpty { print("Drawing pages: \(document.drawingPages.count) (scnotes drawing \(record.id) out.pdf)") }
        }
        if let issue = document.textIssue { fputs("scnotes: \(issue)\n", stderr) }
    }

    static func editIssue(_ document: CloudDocument) -> String? {
        if let issue = document.textIssue { return issue }
        if document.resource.attr("isLocked") == "true" || document.resource.attr("isEncrypted") == "true" { return "Locked or encrypted notes cannot be edited by this version." }
        return nil
    }

    @MainActor static func edit(_ query: String, _ options: Options) async throws {
        guard !options.offline else { throw Failure(message: "Saving needs Samsung Cloud; remove --offline.", code: 2) }
        var newBody: String?
        if let text = options.value("body") { newBody = text }
        if let path = options.value("body-file") {
            guard newBody == nil else { throw Failure(message: "Use either --body or --body-file.", code: 2) }
            let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
            guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "The body must be UTF-8 text.") }
            newBody = text
        }
        let newTitle = options.value("title")
        guard newBody != nil || newTitle != nil else { throw Failure(message: "Nothing to change: pass --title and/or --body/--body-file.", code: 2) }
        let library = try await Library.load(offline: false, strict: true)
        let record = try library.resolve(query)
        guard !record.trashed else { throw Failure(message: "Restore this note from the trash on a Samsung device before editing it.") }
        let document = try await library.client.download(record.id)
        if let issue = editIssue(document) { throw Failure(message: issue) }
        let title = newTitle ?? document.title, body = newBody ?? document.body
        if body != document.body && document.bodyObject == nil { throw Failure(message: "This note has no supported typed-text body.") }
        guard title != document.title || body != document.body else { print("No changes; the cloud copy already matches."); return }
        // Never overwrite an unsaved draft from the window app without consent.
        let draftURL = try LocalStore.directory("Drafts").appendingPathComponent(record.id + ".json")
        if let data = try? Data(contentsOf: draftURL), let draft = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           draft["title"] != document.title || draft["body"] != document.body {
            guard options.flags.contains("discard-draft") else { throw Failure(message: "This note has an unsaved draft in the app. Save or reload it there, or pass --discard-draft to archive it and continue.") }
        }
        try LocalStore.archiveDraft(id: record.id)
        let fresh = try await library.client.save(document, title: title, body: body)
        try library.cache.save(fresh, revision: fresh.commit)
        var index = library.index
        if let position = index.notes.firstIndex(where: { $0.id == record.id }) { index.notes[position].commit = fresh.commit; index.notes[position].describe(fresh) }
        try library.cache.saveIndex(index)
        try LocalStore.writeDraft(id: record.id, title: fresh.title, body: fresh.body, commit: fresh.commit)
        print("Saved \"\(fresh.title.isEmpty ? record.title : fresh.title)\" to Samsung Cloud and verified the readback. A pre-save backup is in \(LocalStore.root.appendingPathComponent("Backups").path).")
    }

    @MainActor static func export(_ query: String, to directory: String, _ options: Options) async throws {
        let library = try await Library.load(offline: options.offline)
        let record = try library.resolve(query)
        let document = try await library.document(record, fresh: true)
        let destination = URL(fileURLWithPath: directory).appendingPathComponent(safeName(record.title) + ".samsungnote")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try document.original.write(to: destination.appendingPathComponent("document.xml"), options: [.atomic])
        try Data(document.body.utf8).write(to: destination.appendingPathComponent("text.txt"), options: [.atomic])
        for asset in document.assets {
            let data: Data
            if let cached = library.cache.asset(id: asset.id, revision: document.commit) { data = cached }
            else {
                guard !library.offline else { throw Failure(message: "Attachment \(asset.fileName) is not cached. Export while online.") }
                data = try await library.client.downloadAsset(asset)
                try library.cache.saveAsset(data, id: asset.id, revision: document.commit)
            }
            try data.write(to: destination.appendingPathComponent(safeName(asset.id)), options: [.atomic])
        }
        print(destination.path)
    }

    @MainActor static func drawing(_ query: String, to path: String, _ options: Options) async throws {
        let library = try await Library.load(offline: options.offline)
        let document = try await library.document(try library.resolve(query), fresh: false)
        guard !document.drawingPages.isEmpty else { throw Failure(message: "This note has no previewable drawing.") }
        try DrawingPage.pdf(document.drawingPages).write(to: URL(fileURLWithPath: path), options: [.atomic])
        print(URL(fileURLWithPath: path).path)
    }

    // MARK: Installation

    static var appBundle: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle : nil
    }
    static func install(into directory: String?) throws -> String {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(), appBundle != nil else {
            throw Failure(message: "Run install from the app executable inside Samsung Cloud Notes.app.")
        }
        let folder = directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(wrapperName)
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\n# Samsung Cloud Notes command line wrapper. Reinstall it if the app moves.\nexec \(quoted) --cli \"$@\"\n"
        try Data(script.utf8).write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let onPath = path.contains(folder.path) || path.contains(folder.path + "/")
        return "Installed \(target.path)." + (onPath ? " Run scnotes help." : "\n\(folder.path) is not on your PATH. Add this line to ~/.zshrc:\n  export PATH=\"\(folder.path):$PATH\"")
    }
    @MainActor static func installFromApp() {
        let alert = NSAlert()
        do {
            alert.messageText = "Command line tool installed"
            alert.informativeText = try install(into: nil)
        } catch {
            alert.messageText = "Could not install the command line tool"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    // MARK: Helpers

    static func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data); print()
    }
    static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let result = String(value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined().prefix(100))
        return result.trimmingCharacters(in: .whitespaces).isEmpty ? "note" : result
    }
}
