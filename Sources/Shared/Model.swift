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
    /// Checklist ticks made here without a text change; nil when the cloud formatting is unchanged.
    @Published var richEdits: RichText?
    @Published var status = "Connect your Samsung account to load your notes."
    @Published var busy = false
    @Published var draftConflict = false
    @Published var error: String?
    @Published var account = ""
    @Published var document: CloudDocument?
    @Published var pendingConnection: Data?
    @Published var importCode = ""
    /// Pictures and tables of the open note by Samsung object id; pictures appear as they download.
    @Published var objects: [String: NoteObject] = [:]
    private var objectsTask: Task<Void, Never>?
    private var objectAssets: [String: String] = [:]
    private var client: CloudClient?
    private var cache: NoteCache?
    private(set) var downloadedNotes = 0
    private(set) var loaded: [String: CloudDocument] = [:]
    private var generation = 0
    private var draftTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    /// Seconds without changes before an edit saves itself to Samsung Cloud.
    static let autosaveDelay: UInt64 = 60
    private var lastCheck = Date.distantPast
    /// The stored draft the open note was shown with (an earlier unsaved edit, or one made in Apple
    /// Notes), so typing here can be told apart from edits that arrived from elsewhere.
    private(set) var restoredDraft: NoteDraft?
    /// Typing here changed the open note (rather than a draft shown from elsewhere).
    var editingHere: Bool {
        guard document != nil, dirty else { return false }
        return restoredDraft.map { currentDraft($0.commit) != $0 } ?? true
    }
    /// Hooks for the Mac's Apple Notes sync: a note was saved, typing started here, other devices changed notes.
    var onSaved: ((CloudDocument) -> Void)?
    var onLocalEdit: (() -> Void)?
    var onCloudChanges: (() -> Void)?
    let drafts: NoteDraftStore
    init(drafts: NoteDraftStore = NoteDraftStore()) { self.drafts = drafts }
    /// Opens the newest note after loading. Compact layouts navigate on selection, so they opt out.
    var autoSelectFirst = true
    var dirty: Bool { document.map { $0.title != title || $0.body != body || richEdits != nil } ?? false }
    /// Formatting shown and saved for the current text: local checklist edits, else the cloud copy's.
    var displayRich: RichText? { richEdits ?? document?.richBody }
    func currentDraft(_ commit: String) -> NoteDraft {
        NoteDraft(title: title, body: body, commit: commit, richText: richEdits?.text, richRanges: richEdits?.ranges)
    }
    func toggleCheckbox(_ paragraph: Int) {
        guard editable, !busy, let base = displayRich else { return }
        let text = StyledText.normalized(body)
        guard let toggled = base.withText(text).togglingCheckbox(paragraph: paragraph) else { return }
        richEdits = document?.richBody?.withText(text).checkStates == toggled.checkStates ? nil : toggled
        scheduleDraft()
    }
    var visibleNotes: [NoteRecord] {
        notes.filter { note in
            let inFolder = folder == "all" ? !note.trashed : folder == "trash" ? note.trashed : note.folder == folder && !note.trashed
            return inFolder && (search.isEmpty || (note.title + " " + note.snippet).localizedCaseInsensitiveContains(search))
        }
    }
    var editable: Bool {
        guard let doc = document else { return false }
        return doc.resource.attr("isLocked") != "true" && doc.resource.attr("isEncrypted") != "true" && doc.editIssue == nil && folder != "trash" && !draftConflict
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
                try drafts.write(currentDraft(document.commit), id: document.serverID)
            }
            try SamsungSignIn.shared.signOut()
            generation += 1
            draftTask?.cancel(); draftTask = nil; autosaveTask?.cancel(); autosaveTask = nil; restoredDraft = nil
            transientSession = nil
            client = nil; cache = nil; loaded = [:]
            document = nil; selection = nil; notes = []; folders = []
            title = ""; body = ""; richEdits = nil; account = ""; folder = "all"; search = ""
            objectsTask?.cancel(); objects = [:]; objectAssets = [:]
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
            let previousActive = Set(notes.filter { !$0.trashed }.map(\.id))
            let index = try await client.loadIndex()
            lastCheck = Date()
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
            // A local draft keeps its original cloud baseline for conflict checks; an unchanged note stays as shown.
            if let id = selection, !dirty, document?.serverID != id || document?.commit != notes.first(where: { $0.id == id })?.commit { await open(id) }
            status = "\(notes.filter { !$0.trashed }.count) notes · Updated \(Date().formatted(date: .omitted, time: .shortened))"
            if failures > 0 { status += " · \(failures) notes could not be downloaded" }
            // Edited, added, or deleted and trashed (no new revision then) on other devices.
            if notes.contains(where: { previous[$0.id] != $0.commit }) || Set(notes.filter { !$0.trashed }.map(\.id)) != previousActive { onCloudChanges?() }
        } catch let error as SamsungHTTPError where error.path.hasPrefix("/auth/oauth2/") && [400, 401, 403].contains(error.status) {
            status = "Samsung sign-in expired · Cached notes and drafts retained. Choose Sign in with Samsung to reconnect."
        } catch {
            status = notes.isEmpty ? "Could not reach Samsung Cloud. Try Refresh." : "Offline · Showing cached notes and local drafts. Try Refresh to reconnect."
            if notes.isEmpty { self.error = error.localizedDescription }
        }
    }
    /// Checks Samsung Cloud for edits made on other devices without locking the editor: the index is
    /// read in the background, and a full refresh (which briefly pauses editing) runs only when
    /// something changed and nothing is being edited here.
    func refreshIfStale(_ interval: TimeInterval) async {
        guard let client, !busy, !dirty, Date().timeIntervalSince(lastCheck) >= interval else { return }
        lastCheck = Date()
        guard let index = try? await client.loadIndex(), !busy, !dirty else { return }
        func signature(_ notes: [NoteRecord], _ folders: [FolderRecord]) -> [String] {
            (notes.map { "\($0.id) \($0.commit) \($0.folder) \($0.trashed) \($0.locked)" } + folders.map { "\($0.id) \($0.name) \($0.parent)" }).sorted()
        }
        guard signature(index.notes, index.folders) != signature(notes, folders) else { return }
        await refresh()
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
        document = doc; title = doc.title; body = doc.body; richEdits = nil; draftConflict = false; restoredDraft = nil
        loadObjects(doc)
        if restoringDraft, let draft = try? drafts.read(id), draft.title != doc.title || draft.body != doc.body || draft.richText != nil {
            title = draft.title; body = draft.body; richEdits = draft.rich; draftConflict = draft.commit != doc.commit; restoredDraft = draft
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
            let current = dirty ? currentDraft(document.commit) : nil
            try drafts.discard(document.serverID,current:current)
            let baseline = loaded[document.serverID] ?? document
            self.document = baseline; title = baseline.title; body = baseline.body; richEdits = nil
            draftConflict = false; error = nil; restoredDraft = nil; autosaveTask?.cancel(); autosaveTask = nil
            status = "Local changes discarded. Showing the downloaded cloud copy; Refresh checks for newer changes. Recovery copy: Local copies → DraftHistory."
        } catch { self.error = "Could not archive your edits; the local draft was kept. " + error.localizedDescription }
    }
    func preserveDraft() {
        // A stored draft shown untouched is already saved, and may since have been replaced by a newer Apple Notes edit.
        guard let document, dirty, !draftConflict, editingHere else { return }
        do { try drafts.write(currentDraft(document.commit),id:document.serverID) }
        catch { self.error = "Could not save your local draft: " + error.localizedDescription }
    }
    func scheduleDraft() {
        draftTask?.cancel()
        guard let document, dirty, !draftConflict else { draftTask = nil; autosaveTask?.cancel(); autosaveTask = nil; return }
        if editingHere { onLocalEdit?() }
        let id = document.serverID, revision = document.commit, ticket = generation
        draftTask = Task {
            try? await Task.sleep(nanoseconds:600_000_000)
            guard !Task.isCancelled, generation == ticket, self.document?.serverID == id, self.document?.commit == revision else { return }
            preserveDraft()
        }
        scheduleAutosave(after: Self.autosaveDelay)
    }
    /// Saves the open note once it has gone `seconds` without changes (typed here or arriving from Apple Notes).
    func scheduleAutosave(after seconds: UInt64) {
        autosaveTask?.cancel(); autosaveTask = nil
        guard let document, dirty, editable else { return }
        let id = document.serverID, ticket = generation
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, generation == ticket, self.document?.serverID == id, dirty, editable else { return }
            if busy { scheduleAutosave(after: 5); return }
            await save()
        }
    }
    /// Saves the stored draft of a note that is not open here (an edit made in Apple Notes), with Save's checks.
    @discardableResult func saveStoredDraft(_ id: String) async -> Bool {
        guard let client, !busy, selection != id, let draft = try? drafts.read(id), let base = loaded[id],
              draft.commit == base.commit, base.editIssue == nil, base.resource.attr("isLocked") != "true" else { return false }
        busy = true; defer { busy = false }
        do {
            let fresh = try await client.save(try CloudDocument(serverID: id, data: base.original), title: draft.title, body: draft.body, rich: draft.rich)
            loaded[id] = fresh
            if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].commit = fresh.commit; describe(i, document: fresh) }
            try cache?.save(fresh, revision: fresh.commit)
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            try drafts.removeIfMatches(id, draft: draft)
            status = "Saved \"\(fresh.title.isEmpty ? "note" : fresh.title)\" from Apple Notes · \(Date().formatted(date: .omitted, time: .shortened))"
            onSaved?(fresh)
            return true
        } catch {
            status = "An Apple Notes edit could not be saved yet; it is kept as a local draft. " + error.localizedDescription
            return false
        }
    }
    func save() async {
        guard let client, let document, !busy, dirty, !draftConflict else { return }
        autosaveTask?.cancel(); autosaveTask = nil
        preserveDraft(); busy = true; status = "Saving to Samsung Cloud…"
        let id = document.serverID; let savedTitle = title; let savedBody = body; let savedRich = richEdits
        defer { busy = false }
        do {
            // Use a fresh object so a failed upload cannot mutate the displayed baseline.
            let copy = try CloudDocument(serverID: id, data: document.original)
            let fresh = try await client.save(copy, title: savedTitle, body: savedBody, rich: savedRich)
            loaded[id] = fresh
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i].commit = fresh.commit
                try cache?.save(fresh, revision: fresh.commit)
            }
            if selection == id { self.document = fresh; title = fresh.title; body = fresh.body; richEdits = nil; restoredDraft = nil; loadObjects(fresh) }
            if let i = notes.firstIndex(where: { $0.id == id }) { describe(i, document: fresh) }
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            try drafts.removeIfMatches(id,draft:NoteDraft(title:savedTitle,body:savedBody,commit:document.commit,richText:savedRich?.text,richRanges:savedRich?.ranges))
            status = "Saved to Samsung Cloud · \(Date().formatted(date: .omitted, time: .shortened))"
            onSaved?(fresh)
        } catch { self.error = error.localizedDescription; status = "Save failed. Your local draft is retained." }
    }
    /// Shows `doc`'s tables at once and fetches its pictures (cache first); pictures already shown are kept.
    func loadObjects(_ doc: CloudDocument) {
        objectsTask?.cancel()
        var next: [String: NoteObject] = [:]
        var pending: [(id: String, asset: AssetRecord)] = []
        for (id, source) in SamsungAttachments.sources(doc) {
            switch source {
            case .table(let cells): next[id] = .table(cells)
            case .image(let asset):
                if objectAssets[id] == asset.id, let shown = objects[id] { next[id] = shown } else { pending.append((id, asset)) }
            }
        }
        objects = next
        objectAssets = objectAssets.filter { next[$0.key] != nil }
        guard !pending.isEmpty else { objectsTask = nil; return }
        let serverID = doc.serverID
        objectsTask = Task {
            for (id, asset) in pending {
                guard !Task.isCancelled else { return }
                guard let data = try? await attachmentData(asset, document: doc), data.count <= 100_000_000,
                      !Task.isCancelled, document?.serverID == serverID else { continue }
                objects[id] = .image(data); objectAssets[id] = asset.id
            }
        }
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
