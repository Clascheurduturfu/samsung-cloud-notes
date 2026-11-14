import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import Combine

@MainActor final class NotesModel: ObservableObject {
    @Published var notes: [NoteRecord] = []
    @Published var folders: [FolderRecord] = []
    @Published var selection: String?
    @Published var folder = "all"
    @Published var search = ""
    @Published var title = ""
    @Published var body = ""
    @Published var status = "Connect your Samsung account to load your notes."
    @Published var busy = false
    @Published var draftConflict = false
    @Published var error: String?
    @Published var account = ""
    @Published var document: CloudDocument?
    @Published var pendingConnection: Data?
    @Published var importCode = ""
    private var client: CloudClient?
    private var cache: NoteCache?
    private(set) var downloadedNotes = 0
    private var loaded: [String: CloudDocument] = [:]
    private var generation = 0
    private var draftTask: Task<Void, Never>?
    private let drafts: NoteDraftStore
    init(drafts: NoteDraftStore = NoteDraftStore()) { self.drafts = drafts }
    /// Opens the newest note after loading. Compact layouts navigate on selection, so they opt out.
    var autoSelectFirst = true
    var dirty: Bool { document.map { $0.title != title || $0.body != body } ?? false }
    var visibleNotes: [NoteRecord] {
        notes.filter { note in
            let inFolder = folder == "all" ? !note.trashed : folder == "trash" ? note.trashed : note.folder == folder && !note.trashed
            return inFolder && (search.isEmpty || (note.title + " " + note.snippet).localizedCaseInsensitiveContains(search))
        }
    }
    var editable: Bool {
        guard let doc = document else { return false }
        return doc.resource.attr("isLocked") != "true" && doc.resource.attr("isEncrypted") != "true" && doc.textIssue == nil && folder != "trash" && !draftConflict
    }
    func connect(cacheOnly: Bool = false) async {
        do {
            let session = try transientSession ?? SessionStore.load()
            preserveDraft()
            client = CloudClient(account: session); account = session.account
            loaded = [:]; document = nil; selection = nil; notes = []; folders = []
            cache = try NoteCache(session: session)
            restoreCache()
            if let id = selection { await open(id) }
            if !cacheOnly { await refresh() }
        } catch { status = error.localizedDescription }
    }
    func signIn(useAnotherAccount: Bool = false) async {
        guard !busy else { return }
        busy = true; preserveDraft()
        do {
            let credentials: NativeCredentials
            if !useAnotherAccount, let saved = try NativeAuthStore.loadIfPresent() { credentials = saved; status = "Connecting your saved Samsung sign-in…" }
            else { credentials = try await SamsungSignIn.shared.signIn(status: { self.status = $0 }) }
            let session: AccountSession
            do { session = try await SamsungSignIn.shared.cloudSession(credentials) }
            catch let error as SamsungHTTPError where error.path.hasPrefix("/auth/oauth2/") && [400, 401, 403].contains(error.status) {
                status = "Samsung needs a new browser sign-in…"
                let fresh = try await SamsungSignIn.shared.signIn(status: { self.status = $0 })
                session = try await SamsungSignIn.shared.cloudSession(fresh)
            }
            status = "Checking Notes access…"
            _ = try await CloudClient(account: session).loadIndex()
            try SessionStore.save(session)
            busy = false
            await connect()
        } catch { busy = false; self.error = error.localizedDescription; status = "Samsung sign-in did not finish. Your existing notes and local drafts are retained." }
    }
    func signOut() {
        guard !busy else { return }
        do {
            if let document, dirty, !draftConflict {
                try LocalStore.writeDraft(id: document.serverID, title: title, body: body, commit: document.commit)
            }
            try SamsungSignIn.shared.signOut()
            generation += 1
            draftTask?.cancel(); draftTask = nil
            transientSession = nil
            client = nil; cache = nil; loaded = [:]
            document = nil; selection = nil; notes = []; folders = []
            title = ""; body = ""; account = ""; folder = "all"; search = ""
            draftConflict = false; downloadedNotes = 0
            pendingConnection = nil; importCode = ""; error = nil
            status = "Signed out. Sign in with Samsung to load your notes."
        } catch { self.error = "Could not log out: " + error.localizedDescription }
    }
    func importConnection(_ data: Data, code: String = "") async {
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let sessionData: Data
            if let sealed = json?["sealed"] as? String {
                guard json?["format"] as? String == "samsung-cloud-notes-connection", json?["version"] as? Int == 1 else { throw NotesError.message("This connection file version is not supported.") }
                guard let keyData = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), keyData.count == 32,
                      let combined = Data(base64Encoded: sealed) else { throw NotesError.message("Paste the 44-character connection code shown by the Windows exporter.") }
                let box = try AES.GCM.SealedBox(combined: combined)
                sessionData = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            } else { sessionData = data }
            let session = try JSONDecoder().decode(AccountSession.self, from: sessionData)
            try SessionStore.save(session)
            pendingConnection = nil; importCode = ""
            await connect()
        } catch { self.error = "Could not import the connection: " + error.localizedDescription }
    }
    func restoreCache() {
        guard let snapshot = cache?.snapshot() else { return }
        notes = snapshot.index.notes; folders = snapshot.index.folders
        for record in notes {
            if let doc = cache?.document(record) { loaded[record.id] = doc }
        }
        if autoSelectFirst { selection = visibleNotes.first?.id }
        status = "Cached notes · Last synced " + snapshot.updated.formatted(date: .abbreviated, time: .shortened)
    }
    func refresh() async {
        guard let client, !busy else { return }
        preserveDraft()
        busy = true; downloadedNotes = 0
        status = notes.isEmpty ? "Reading Samsung Cloud…" : "Checking Samsung Cloud for changes…"
        defer { busy = false }
        do {
            let previous = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.commit) })
            let index = try await client.loadIndex()
            notes = index.notes; folders = index.folders
            let allowed = Set(notes.filter { !$0.locked && !$0.encrypted }.map(\.id))
            loaded = loaded.filter { allowed.contains($0.key) }
            var failures = 0
            for record in notes {
                if record.locked || record.encrypted { continue }
                var doc: CloudDocument?
                if previous[record.id] == record.commit, let existing = loaded[record.id] { doc = existing }
                else if let cached = cache?.document(record) { doc = cached; loaded[record.id] = cached }
                else {
                    do {
                        let fresh = try await client.download(record.id)
                        downloadedNotes += 1; loaded[record.id] = fresh; doc = fresh
                        try cache?.save(fresh, revision: record.commit)
                    } catch {
                        if error is CancellationError { throw error }
                        // Never label an old document as matching a new revision.
                        loaded.removeValue(forKey: record.id); doc = nil; failures += 1
                    }
                }
                if let doc, let i = notes.firstIndex(where: { $0.id == record.id }) { describe(i, document: doc) }
            }
            try cache?.prune(notes)
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            if let id = selection, !notes.contains(where: { $0.id == id && !$0.locked && !$0.encrypted }) {
                selection = nil; document = nil
            }
            if selection == nil, autoSelectFirst { selection = visibleNotes.first?.id }
            // A local draft keeps its original cloud baseline for conflict checks.
            if let id = selection, !dirty { await open(id) }
            status = "\(notes.filter { !$0.trashed }.count) notes · Updated \(Date().formatted(date: .omitted, time: .shortened))"
            if failures > 0 { status += " · \(failures) notes could not be downloaded" }
        } catch let error as SamsungHTTPError where error.path.hasPrefix("/auth/oauth2/") && [400, 401, 403].contains(error.status) {
            status = "Samsung sign-in expired · Cached notes and drafts retained. Choose Sign in with Samsung to reconnect."
        } catch {
            status = notes.isEmpty ? "Could not reach Samsung Cloud. Try Refresh." : "Offline · Showing cached notes and local drafts. Try Refresh to reconnect."
            if notes.isEmpty { self.error = error.localizedDescription }
        }
    }
    private func describe(_ index: Int, document: CloudDocument) { notes[index].describe(document) }
    func select(_ id: String?) async {
        preserveDraft()
        if let id { await open(id) } else { document = nil }
    }
    func open(_ id: String, force: Bool = false) async {
        guard let client else { return }
        generation += 1; let taskGeneration = generation
        do {
            let doc: CloudDocument
            let downloaded: Bool
            if !force, let cached = loaded[id] { doc = cached; downloaded = false }
            else {
                doc = try await client.download(id); downloaded = true
            }
            guard generation == taskGeneration, selection == id else { return }
            try present(doc,restoringDraft:!force,persistDownloadedCopy:downloaded)
        } catch {
            guard generation == taskGeneration, selection == id else { return }
            self.error = error.localizedDescription
            if force { status = "Could not reload the cloud copy. Discard local changes to clear the draft without a connection." }
        }
    }
    func present(_ doc: CloudDocument, restoringDraft: Bool = true, persistDownloadedCopy: Bool = false) throws {
        let id = doc.serverID
        if !restoringDraft { try drafts.discard(id) }
        draftTask?.cancel(); draftTask = nil
        loaded[id] = doc
        if let index = notes.firstIndex(where:{ $0.id == id }) { notes[index].commit = doc.commit; describe(index,document:doc) }
        if persistDownloadedCopy {
            try cache?.save(doc,revision:doc.commit)
            try cache?.saveIndex(CloudIndex(notes:notes,folders:folders))
        }
        document = doc; title = doc.title; body = doc.body; draftConflict = false
        if restoringDraft, let draft = try? drafts.read(id), draft.title != doc.title || draft.body != doc.body {
            title = draft.title; body = draft.body; draftConflict = draft.commit != doc.commit
            status = draftConflict ? "This Mac has unsaved edits from an older cloud copy. Discard local changes to use the downloaded note." : "Recovered unsaved local edits. Save when ready."
        } else {
            // Older clients wrote saved cloud baselines into Drafts. Remove a
            // matching baseline before a later cloud edit turns it into a false conflict.
            if restoringDraft, let clean = try? drafts.read(id), clean.title == doc.title, clean.body == doc.body {
                try drafts.removeIfMatches(id,draft:clean)
            }
            if !restoringDraft { status = "Cloud copy loaded. Previous local edits are archived in Local copies." }
        }
    }
    func reloadFromCloud() async {
        guard !busy, let id = selection else { return }
        preserveDraft(); draftTask?.cancel(); draftTask = nil
        busy = true; status = "Downloading the cloud copy…"
        defer { busy = false }
        await open(id,force:true)
    }
    func discardLocalChanges() {
        guard !busy, let document else { return }
        draftTask?.cancel(); draftTask = nil; generation += 1
        do {
            let current = dirty ? NoteDraft(title:title,body:body,commit:document.commit) : nil
            try drafts.discard(document.serverID,current:current)
            let baseline = loaded[document.serverID] ?? document
            self.document = baseline; title = baseline.title; body = baseline.body
            draftConflict = false; error = nil
            status = "Local changes discarded. Showing the downloaded cloud copy; Refresh checks for newer changes. Recovery copy: Local copies → DraftHistory."
        } catch { self.error = "Could not archive your edits; the local draft was kept. " + error.localizedDescription }
    }
    func preserveDraft() {
        guard let document, dirty, !draftConflict else { return }
        do { try drafts.write(NoteDraft(title:title,body:body,commit:document.commit),id:document.serverID) }
        catch { self.error = "Could not save your local draft: " + error.localizedDescription }
    }
    func scheduleDraft() {
        draftTask?.cancel()
        guard let document, dirty, !draftConflict else { draftTask = nil; return }
        let id = document.serverID, revision = document.commit, ticket = generation
        draftTask = Task {
            try? await Task.sleep(nanoseconds:600_000_000)
            guard !Task.isCancelled, generation == ticket, self.document?.serverID == id, self.document?.commit == revision else { return }
            preserveDraft()
        }
    }
    func save() async {
        guard let client, let document, !busy, dirty, !draftConflict else { return }
        preserveDraft(); busy = true; status = "Saving to Samsung Cloud…"
        let id = document.serverID; let savedTitle = title; let savedBody = body
        defer { busy = false }
        do {
            // Use a fresh object so a failed upload cannot mutate the displayed baseline.
            let copy = try CloudDocument(serverID: id, data: document.original)
            let fresh = try await client.save(copy, title: savedTitle, body: savedBody)
            loaded[id] = fresh
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i].commit = fresh.commit
                try cache?.save(fresh, revision: fresh.commit)
            }
            if selection == id { self.document = fresh; title = fresh.title; body = fresh.body }
            if let i = notes.firstIndex(where: { $0.id == id }) { describe(i, document: fresh) }
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            try drafts.removeIfMatches(id,draft:NoteDraft(title:savedTitle,body:savedBody,commit:document.commit))
            status = "Saved to Samsung Cloud · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch { self.error = error.localizedDescription; status = "Save failed. Your local draft is retained." }
    }
    func attachmentData(_ asset: AssetRecord, document: CloudDocument) async throws -> Data {
        if let data = cache?.asset(id: asset.id, revision: document.commit) { return data }
        guard let client else { throw NotesError.message("Connect to Samsung Cloud to download this attachment.") }
        // Cached XML deliberately omits expiring signed download URLs.
        var current = asset
        if current.url == nil {
            let fresh = try await client.download(document.serverID)
            guard fresh.commit == document.commit, let found = fresh.assets.first(where: { $0.id == asset.id }) else {
                throw NotesError.message("This note changed. Refresh its cloud copy to open the attachment.")
            }
            current = found
        }
        let data = try await client.downloadAsset(current)
        try cache?.saveAsset(data, id: asset.id, revision: document.commit)
        return data
    }
    func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(result.prefix(100)).isEmpty ? "note" : String(result.prefix(100))
    }
}

extension NoteRecord {
    /// List metadata derived from a downloaded document.
    mutating func describe(_ document: CloudDocument) {
        let heading = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = document.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = heading.isEmpty ? (firstLine.isEmpty ? "Untitled note" : firstLine) : heading
        snippet = String(document.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        resourceID = document.resource.attr("id")
    }
}
