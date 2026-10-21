import SwiftUI
import AppKit
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import UniformTypeIdentifiers

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
        selection = visibleNotes.first?.id
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
            if selection == nil { selection = visibleNotes.first?.id }
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
    private func describe(_ index: Int, document: CloudDocument) {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = document.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        notes[index].title = title.isEmpty ? (firstLine.isEmpty ? "Untitled note" : firstLine) : title
        notes[index].snippet = String(document.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        notes[index].resourceID = document.resource.attr("id")
    }
    func select(_ id: String?) async {
        preserveDraft()
        if let id { await open(id) } else { document = nil }
    }
    func open(_ id: String, force: Bool = false) async {
        guard let client else { return }
        generation += 1; let taskGeneration = generation
        do {
            let doc: CloudDocument
            if !force, let cached = loaded[id] { doc = cached }
            else {
                doc = try await client.download(id); loaded[id] = doc
                if let record = notes.first(where: { $0.id == id }) { try cache?.save(doc, revision: record.commit) }
            }
            guard generation == taskGeneration, selection == id else { return }
            document = doc; title = doc.title; body = doc.body; draftConflict = false
            if force {
                try LocalStore.archiveDraft(id: id)
                try LocalStore.writeDraft(id: id, title: doc.title, body: doc.body, commit: doc.commit)
            }
            if !force, let draftURL = try? LocalStore.directory("Drafts").appendingPathComponent(id + ".json"),
               let draft = try? Data(contentsOf: draftURL),
               let values = try? JSONSerialization.jsonObject(with: draft) as? [String: String],
               let draftTitle = values["title"], let draftBody = values["body"], (draftBody != doc.body || draftTitle != doc.title) {
                title = draftTitle; body = draftBody
                draftConflict = values["commit"] != doc.commit
                status = draftConflict ? "Draft is based on an older revision. Reload to archive it and use the cloud copy." : "Recovered an unsaved local draft. Save when ready."
            }
        } catch {
            guard generation == taskGeneration, selection == id else { return }
            self.error = error.localizedDescription
        }
    }
    func preserveDraft() {
        guard let document, dirty, !draftConflict else { return }
        do { try LocalStore.writeDraft(id: document.serverID, title: title, body: body, commit: document.commit) }
        catch { self.error = "Could not save your local draft: " + error.localizedDescription }
    }
    func scheduleDraft() {
        draftTask?.cancel()
        draftTask = Task { try? await Task.sleep(nanoseconds: 600_000_000); if !Task.isCancelled { preserveDraft() } }
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
            try LocalStore.writeDraft(id: id, title: savedTitle, body: savedBody, commit: fresh.commit)
            if selection == id { self.document = fresh; title = fresh.title; body = fresh.body }
            if let i = notes.firstIndex(where: { $0.id == id }) { describe(i, document: fresh) }
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            status = "Saved to Samsung Cloud · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch { self.error = error.localizedDescription; status = "Save failed. Your local draft is retained." }
    }
    func export() async {
        guard let document else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(safeName(title.isEmpty ? "Samsung note" : title)).samsungnote"
        panel.title = "Export original Samsung Cloud document and attachments"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try document.original.write(to: destination.appendingPathComponent("document.xml"), options: [.atomic])
            try Data(body.utf8).write(to: destination.appendingPathComponent("text.txt"), options: [.atomic])
            for asset in document.assets {
                let data = try await attachmentData(asset, document: document)
                let name = safeName(asset.id)
                try data.write(to: destination.appendingPathComponent(name), options: [.atomic])
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination]); status = "Exported original document and \(document.assets.count) attachments."
        } catch { self.error = "Export did not finish: " + error.localizedDescription }
    }
    private func attachmentData(_ asset: AssetRecord, document: CloudDocument) async throws -> Data {
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
    func showAttachment(_ asset: AssetRecord) async {
        guard let document else { return }
        do {
            guard !asset.isInternal else { throw NotesError.message("This is an internal Samsung page resource. Use the drawing preview or export the original document.") }
            let data = try await attachmentData(asset, document: document)
            let ext: String
            if data.starts(with: [0x89,0x50,0x4e,0x47]) { ext = ".png" }
            else if data.starts(with: [0xff,0xd8,0xff]) { ext = ".jpg" }
            else if data.starts(with: Data("%PDF".utf8)) { ext = ".pdf" }
            else if NSImage(data: data) != nil {
                let image = NSImage(data: data)!
                guard let png = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) else { throw NotesError.message("This image could not be opened.") }
                let url = try LocalStore.directory("Attachments").appendingPathComponent(safeName(asset.id) + ".png")
                try png.write(to: url, options: [.atomic]); NSWorkspace.shared.open(url); return
            }
            else {
                let suffix = (asset.fileName as NSString).pathExtension.lowercased()
                guard ["txt", "csv", "rtf", "docx", "xlsx", "pptx", "mp3", "m4a", "wav", "mp4", "mov"].contains(suffix) else { throw NotesError.message("This Samsung resource has no supported preview. Export the original document to keep it.") }
                ext = "." + suffix
            }
            let url = try LocalStore.directory("Attachments").appendingPathComponent(safeName(asset.fileName) + "-" + safeName(asset.id) + ext)
            try data.write(to: url, options: [.atomic])
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
    func showDrawing() {
        guard let document else { return }
        do {
            let url = try LocalStore.directory("Previews").appendingPathComponent(safeName(document.serverID) + ".pdf")
            try DrawingPage.pdf(document.drawingPages).write(to: url, options: [.atomic])
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
    private func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(result.prefix(100)).isEmpty ? "note" : String(result.prefix(100))
    }
}

struct NotesView: View {
    @StateObject var model = NotesModel()
    @State var importing = false
    @State var showDrawing = false
    var body: some View {
        VStack(spacing: 0) {
        NavigationSplitView {
            VStack(spacing: 0) {
            List(selection: $model.folder) {
                Label("All notes", systemImage: "doc.text").tag("all")
                Section("Folders") {
                    ForEach(model.folders) { folder in Label(folder.name, systemImage: "folder").tag(folder.id) }
                }
                Label("Trash", systemImage: "trash").tag("trash")
            }
            .navigationTitle("Samsung Cloud Notes")
            Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if !model.account.isEmpty {
                        Menu {
                            Button("Log out", role: .destructive) { model.signOut() }
                        } label: {
                            Text(model.account).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .disabled(model.busy).help("Account options for " + model.account)
                        .accessibilityLabel("Account: " + model.account)
                    }
                    Text("Version \(appVersion)").foregroundStyle(.secondary)
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .navigationSplitViewColumnWidth(min: 185, ideal: 210)
        } content: {
            List(model.visibleNotes, selection: $model.selection) { note in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(note.locked ? "Locked note" : note.title).fontWeight(.medium).lineLimit(2)
                        if note.locked || note.encrypted { Image(systemName: "lock") } }
                    Text(note.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(Date(timeIntervalSince1970: note.modified / 1000), style: .date).font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 5).tag(note.id)
            }
            .searchable(text: $model.search, prompt: "Search notes")
            .navigationSplitViewColumnWidth(min: 230, ideal: 290)
        } detail: {
            if let document = model.document {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Title", text: $model.title).font(.title2).textFieldStyle(.plain).padding()
                        .disabled(!model.editable || model.busy)
                    Divider()
                    if !document.drawingPages.isEmpty {
                        HStack {
                            Picker("View", selection: $showDrawing) { Text("Text").tag(false); Text("Drawing").tag(true) }.pickerStyle(.segmented).frame(width: 190)
                            Spacer()
                            Button("Open drawing PDF") { model.showDrawing() }
                        }.padding(10)
                    }
                    if showDrawing && !document.drawingPages.isEmpty { DrawingPreview(pages: document.drawingPages) }
                    else {
                        TextEditor(text: $model.body).font(.system(size: 15)).padding(10)
                            .disabled(!model.editable || model.busy || document.bodyObject == nil)
                    }
                    if !document.assets.filter({ !$0.isInternal }).isEmpty {
                        Divider()
                        ScrollView(.horizontal) { HStack {
                            Image(systemName: "paperclip")
                            ForEach(document.assets.filter { !$0.isInternal }) { asset in
                                Button(asset.fileName) { Task { await model.showAttachment(asset) } }.lineLimit(1)
                            }
                        }.padding(10) }
                    }
                    if let issue = document.textIssue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(10) }
                    if model.draftConflict { Text("This local draft is based on an older cloud revision. Reload the note to archive the draft and open the current cloud copy.").font(.caption).foregroundStyle(.orange).padding(10) }
                    Divider()
                    HStack {
                        Text(model.dirty ? "Local draft" : "Cloud copy").foregroundStyle(model.dirty ? .orange : .secondary)
                        Spacer()
                        Text("Plain text editing · drawings and attachments retained").foregroundStyle(.secondary)
                    }.font(.caption).padding(10)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "note.text").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(model.account.isEmpty ? "Your Samsung notes, on Mac" : "Select a note").font(.title2)
                    Text(model.account.isEmpty ? "Sign in with your Samsung account to access your notes directly from this Mac." : "Notes load directly from Samsung Cloud.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    if model.account.isEmpty {
                        Button("Sign in with Samsung…") { Task { await model.signIn() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                        Button("Import Windows connection…") { importing = true }.buttonStyle(.link).disabled(model.busy)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy || model.account.isEmpty)
            Button { Task { if let id = model.selection { model.preserveDraft(); await model.open(id, force: true) } } } label: { Label("Reload note", systemImage: "arrow.down.doc") }.disabled(model.busy || model.document == nil)
            Button { Task { await model.export() } } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(model.busy || model.document == nil)
            Button { do { _ = try LocalStore.directory("Backups"); NSWorkspace.shared.open(LocalStore.root) } catch { model.error = error.localizedDescription } } label: { Label("Local copies", systemImage: "folder") }
            Button { Task { await model.save() } } label: { Label("Save to cloud", systemImage: "icloud.and.arrow.up") }.disabled(model.busy || !model.dirty || !model.editable).keyboardShortcut("s")
        }
        Divider()
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).frame(height: 32).background(.bar)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if dictionary?["sealed"] != nil { model.pendingConnection = data }
                else { Task { await model.importConnection(data) } }
            } catch { model.error = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { model.pendingConnection != nil }, set: { if !$0 { model.pendingConnection = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Unlock Samsung connection").font(.title2)
                Text("Paste the connection code shown by the Windows exporter. Your session will be stored in this Mac's Keychain.").frame(width: 390)
                SecureField("Connection code", text: $model.importCode).textFieldStyle(.roundedBorder)
                HStack { Button("Cancel") { model.pendingConnection = nil }; Spacer(); Button("Connect") { if let data = model.pendingConnection { Task { await model.importConnection(data, code: model.importCode) } } }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 440)
        }
        .alert("Samsung Cloud Notes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.selection) { value in Task { await model.select(value) } }
        .onChange(of: model.title) { _ in model.scheduleDraft() }
        .onChange(of: model.body) { _ in model.scheduleDraft() }
        .onChange(of: model.document?.serverID) { _ in showDrawing = model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(model.document?.drawingPages.isEmpty ?? true) }
        .onChange(of: model.folder) { _ in model.preserveDraft(); model.selection = model.visibleNotes.first?.id }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.preserveDraft() }
        .task { await model.connect() }
        .frame(minWidth: 900, minHeight: 580)
    }
}

@main struct SamsungCloudNotesApp: App {
    init() {
        if CommandLine.arguments.contains("--session-stdin") {
            do { transientSession = try JSONDecoder().decode(AccountSession.self, from: FileHandle.standardInput.readDataToEndOfFile()) }
            catch { fputs("Invalid session input.\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--import-session") {
            do { try SessionStore.save(JSONDecoder().decode(AccountSession.self, from: FileHandle.standardInput.readDataToEndOfFile())); print("Session imported into Keychain."); exit(0) }
            catch { fputs("Session import failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try Self.selfTest(); print("Offline self-tests passed."); exit(0) }
            catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--verify-signout") {
            Task { @MainActor in
                do {
                    let model = NotesModel()
                    await model.connect()
                    guard !model.account.isEmpty, !model.notes.isEmpty else { throw NotesError.message("Connect before checking account sign-out.") }
                    let native = try NativeAuthStore.load()
                    let session = try SessionStore.load()
                    let count = model.notes.count
                    defer {
                        do { try NativeAuthStore.save(native); try SessionStore.save(session) }
                        catch { fputs("Could not restore the saved test connection: \(error.localizedDescription)\n", stderr) }
                    }
                    model.signOut()
                    guard model.account.isEmpty, model.notes.isEmpty, model.document == nil,
                          try NativeAuthStore.loadIfPresent() == nil else { throw NotesError.message("Sign-out did not clear the account and native credentials.") }
                    var missing = false
                    do { _ = try SessionStore.load() }
                    catch CredentialError.status(errSecItemNotFound) { missing = true }
                    guard missing else { throw NotesError.message("Sign-out retained its saved cloud session.") }
                    try NativeAuthStore.save(native); try SessionStore.save(session)
                    await model.connect()
                    guard model.notes.count == count, !model.account.isEmpty else { throw NotesError.message("Saved connection could not be restored after the sign-out check.") }
                    print("Account sign-out verified: both credential records removed and visible library cleared; original connection restored in memory and reconnected to \(count) records. Cache and drafts retained.")
                    exit(0)
                } catch { fputs("Account sign-out verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-native") {
            Task { @MainActor in
                do {
                    var expired = try NativeAuthStore.load()
                    let scope = expired.cacheID
                    expired.accessExpires = .distantPast; expired.cloudExpires = .distantPast
                    let renewed = try await SamsungSignIn.shared.cloudSession(expired, force: true)
                    guard renewed.nativeID == scope, let expiry = renewed.expiresAt, expiry > Date().addingTimeInterval(120) else { throw NotesError.message("Native renewal did not retain the device identity or return a valid expiry.") }
                    let index = try await CloudClient(account: renewed).loadIndex()
                    try SessionStore.save(renewed)
                    var rejected = renewed
                    rejected.authorization = "Bearer synthetic-expired-credential-for-renewal-test"
                    let retried = try await CloudClient(account: rejected).loadIndex()
                    guard retried.notes.count == index.notes.count else { throw NotesError.message("Authentication rejection recovery changed the library.") }
                    print("Native Mac sign-in verified: \(index.notes.count) records; forced account/service renewal and rejected-token recovery succeeded; stable device identity retained. No Windows credentials supplied.")
                    exit(0)
                } catch { fputs("Native sign-in verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-cache") {
            Task { @MainActor in
                do {
                    let first = NotesModel()
                    await first.connect()
                    guard !first.notes.isEmpty else { throw NotesError.message("No cloud index available for the cache check.") }
                    let offline = NotesModel()
                    await offline.connect(cacheOnly: true)
                    guard offline.document != nil, offline.notes.count == first.notes.count else { throw NotesError.message("Offline startup could not open the cached library.") }
                    let second = NotesModel()
                    await second.connect()
                    guard second.downloadedNotes == 0, second.notes.count == first.notes.count, second.document != nil else { throw NotesError.message("Warm startup downloaded unchanged documents or failed to restore notes.") }
                    print("Cache verified: \(second.notes.count) records restored offline; first refresh downloaded \(first.downloadedNotes) changed/missing documents; warm refresh downloaded zero unchanged documents.")
                    exit(0)
                } catch { fputs("Cache verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-previews") {
            Task {
                do {
                    let client = CloudClient(account: try transientSession ?? SessionStore.load())
                    let index = try await client.loadIndex()
                    var pages = 0, strokes = 0, unsupported = 0, caches = 0
                    for note in index.notes where !note.locked && !note.encrypted && !note.trashed {
                        let doc = try await client.download(note.id)
                        caches += doc.assets.filter { $0.isInternal }.count
                        guard !doc.drawingPages.isEmpty else { continue }
                        let data = try DrawingPage.pdf(doc.drawingPages)
                        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages == doc.drawingPages.count else { throw NotesError.message("Drawing PDF page verification failed.") }
                        pages += doc.drawingPages.count
                        strokes += doc.drawingPages.reduce(0) { $0 + $1.strokes.count }
                        unsupported += doc.drawingPages.reduce(0) { $0 + $1.unsupported }
                    }
                    print("Cloud drawing verification: \(pages) pages, \(strokes) decoded strokes, \(unsupported) unsupported page objects, \(caches) internal resources hidden from attachments. PDF page counts verified.")
                    exit(0)
                } catch { fputs("Drawing verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-cloud") {
            Task {
                do {
                    let client = CloudClient(account: try transientSession ?? SessionStore.load())
                    let index = try await client.loadIndex()
                    print("Cloud index: \(index.notes.filter { !$0.trashed }.count) normal notes, \(index.notes.filter { $0.trashed }.count) trashed notes, \(index.folders.count) folders.")
                    if let note = index.notes.first(where: { !$0.locked && !$0.encrypted }) {
                        let doc = try await client.download(note.id)
                        print("Cloud document downloaded: \(doc.original.count) bytes, \(doc.body.utf16.count) text units, \(doc.assets.count) attachments.")
                    }
                    exit(0)
                } catch { fputs("Cloud verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--test-save") {
            guard let position = CommandLine.arguments.firstIndex(of: "--test-save"), CommandLine.arguments.count > position + 1 else { exit(2) }
            let id = CommandLine.arguments[position + 1]
            Task {
                do {
                    let client = CloudClient(account: try transientSession ?? SessionStore.load())
                    let doc = try await client.download(id)
                    guard doc.body.contains("Samsung Notes Mac sync test v0.1.0") else { throw NotesError.message("This is not the isolated test note.") }
                    let newBody = "Samsung Notes Mac sync test v0.1.0\nEdited on macOS through Samsung Cloud.\nUnicode: café — 日本語 🚀.\n"
                    let fresh = try await client.save(doc, title: "Mac sync verification (\(appVersion))", body: newBody)
                    guard fresh.body == newBody else { throw NotesError.message("Mac edit readback mismatch.") }
                    let stale = try CloudDocument(serverID: id, data: doc.original)
                    var rejected = false
                    do { _ = try await client.save(stale, title: "Stale edit must be rejected", body: "Must never be written") }
                    catch { rejected = error.localizedDescription.contains("changed on another device") }
                    guard rejected else { throw NotesError.message("Stale revision was not rejected.") }
                    let afterConflict = try await client.download(id)
                    guard afterConflict.body == newBody else { throw NotesError.message("Conflict check modified the note.") }
                    print("Mac cloud edit and readback passed, including Unicode. Stale revision rejected without changing the cloud note.")
                    exit(0)
                } catch { fputs("Mac save test failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
    }
    var body: some Scene { WindowGroup { NotesView() }.defaultSize(width: 1150, height: 760) }
    static func selfTest() throws {
        guard SamsungAuthCrypto.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" else { throw NotesError.message("PKCE reference vector failed.") }
        let callbackKey = Data("0123456789abcdef".utf8)
        let encryptedCallback = try SamsungAuthCrypto.aes(Data("synthetic-callback".utf8), key: callbackKey, encrypt: true, ecb: true).map { String(format: "%02x", $0) }.joined()
        guard try SamsungAuthCrypto.callback(encryptedCallback, key: "0123456789abcdef-extra") == "synthetic-callback" else { throw NotesError.message("Samsung callback decryption failed.") }
        do { _ = try SamsungAuthCrypto.callback("not-hex", key: "test"); throw NotesError.message("Malformed callback was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Malformed callback was accepted." { throw error } }
        let cases = ["", "hello", "café — 日本語 🚀", "first\nsecond\n", "<&> \"quotes\""]
        for value in cases { guard try StyledText.decode(StyledText.encode(value)) == value else { throw NotesError.message("Text round-trip mismatch.") } }
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
        let fixtureXML = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\" unknownField=\"retain\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><text>\(StyledText.encode("Before"))</text></object></bodyText><pageList><page id=\"page\"><opaqueDrawing value=\"preserve\"/></page></pageList><contentFileList><contentFile id=\"asset\" hash=\"original\"/></contentFileList></noteResource><commitId>fixture-revision</commitId><downloadUrls/></CompareNoteView>"
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
        let updated = try XMLDocument(data: fixture.uploadXML(title: "Test title", body: "After 日本語 🚀"))
        guard updated.rootElement()?.attr("unknownField") == "retain",
              try updated.nodes(forXPath: "/noteResource/pageList/page/opaqueDrawing[@value='preserve']").count == 1,
              try updated.nodes(forXPath: "/noteResource/contentFileList/contentFile[@hash='original']").count == 1 else { throw NotesError.message("Opaque drawing or attachment metadata was lost.") }
    }
}
