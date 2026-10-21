import SwiftUI
import AppKit
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import UniformTypeIdentifiers

extension NotesModel {
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
        if CommandLine.arguments.dropFirst().first == "--cli" { CommandLineTool.run(Array(CommandLine.arguments.dropFirst(2))) }
        if CommandLine.arguments.contains("--session-stdin") {
            do { transientSession = try JSONDecoder().decode(AccountSession.self, from: FileHandle.standardInput.readDataToEndOfFile()) }
            catch { fputs("Invalid session input.\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--import-session") {
            do { try SessionStore.save(JSONDecoder().decode(AccountSession.self, from: FileHandle.standardInput.readDataToEndOfFile())); print("Session imported into Keychain."); exit(0) }
            catch { fputs("Session import failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try SelfTest.run(); print("Offline self-tests passed."); exit(0) }
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
    var body: some Scene {
        WindowGroup { NotesView() }.defaultSize(width: 1150, height: 760)
            .commands {
                CommandGroup(after: .appSettings) {
                    Button("Install Command Line Tool…") { CommandLineTool.installFromApp() }
                }
            }
    }

}
