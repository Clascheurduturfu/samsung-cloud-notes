import SwiftUI
import UIKit
import QuickLook
import UniformTypeIdentifiers

extension NotesModel {
    /// Writes an attachment where Quick Look can preview it.
    func attachmentURL(_ asset: AssetRecord) async -> URL? {
        guard let document else { return nil }
        do {
            guard !asset.isInternal else { throw NotesError.message("This is an internal Samsung page resource. Use the drawing preview or export the original document.") }
            let data = try await attachmentData(asset, document: document)
            let ext: String
            if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { ext = ".png" }
            else if data.starts(with: [0xff, 0xd8, 0xff]) { ext = ".jpg" }
            else if data.starts(with: Data("%PDF".utf8)) { ext = ".pdf" }
            else if let image = UIImage(data: data), let png = image.pngData() {
                let url = try LocalStore.directory("Attachments").appendingPathComponent(safeName(asset.id) + ".png")
                try png.write(to: url, options: [.atomic, .completeFileProtection]); return url
            } else {
                let suffix = (asset.fileName as NSString).pathExtension.lowercased()
                guard ["txt", "csv", "rtf", "docx", "xlsx", "pptx", "mp3", "m4a", "wav", "mp4", "mov"].contains(suffix) else { throw NotesError.message("This Samsung resource has no supported preview. Export the original document to keep it.") }
                ext = "." + suffix
            }
            let url = try LocalStore.directory("Attachments").appendingPathComponent(safeName(asset.fileName) + "-" + safeName(asset.id) + ext)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func drawingURL() -> URL? {
        guard let document else { return nil }
        do {
            let url = try LocalStore.directory("Previews").appendingPathComponent(safeName(document.serverID) + ".pdf")
            try DrawingPage.pdf(document.drawingPages).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    /// The same `.samsungnote` layout as the Mac export, zipped for sharing.
    func exportArchive() async -> URL? {
        guard let document else { return nil }
        busy = true; defer { busy = false }
        let fileManager = FileManager.default
        do {
            let staging = fileManager.temporaryDirectory.appendingPathComponent("Export-" + UUID().uuidString, isDirectory: true)
            let folder = staging.appendingPathComponent("\(safeName(title.isEmpty ? "Samsung note" : title)).samsungnote", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }
            try document.original.write(to: folder.appendingPathComponent("document.xml"), options: [.atomic])
            try Data(body.utf8).write(to: folder.appendingPathComponent("text.txt"), options: [.atomic])
            for asset in document.assets {
                try await attachmentData(asset, document: document).write(to: folder.appendingPathComponent(safeName(asset.id)), options: [.atomic])
            }
            // Coordinated reading "for uploading" produces a ZIP of a directory.
            var zipped: URL?; var failure: NSError?; var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &failure) { temporary in
                do {
                    let target = fileManager.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
                    try? fileManager.removeItem(at: target)
                    try fileManager.copyItem(at: temporary, to: target); zipped = target
                } catch { copyError = error }
            }
            if let failure { throw failure }
            if let copyError { throw copyError }
            status = "Exported original document and \(document.assets.count) attachments."
            return zipped
        } catch { self.error = "Export did not finish: " + error.localizedDescription; return nil }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable { let url: URL; var id: URL { url } }

struct NotesRootView: View {
    @StateObject var model = NotesModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var showDrawing = false
    @State private var preview: URL?
    @State private var shared: SharedFile?
    @State private var confirmLogout = false

    private var folderSelection: Binding<String?> { Binding(get: { model.folder }, set: { model.folder = $0 ?? "all" }) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            noteList
        } detail: {
            detail
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
            NavigationStack {
                Form {
                    Section(footer: Text("Paste the connection code shown by the Windows exporter. Your session will be stored in this device's Keychain.")) {
                        SecureField("Connection code", text: $model.importCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                .navigationTitle("Unlock connection").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pendingConnection = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Connect") { if let data = model.pendingConnection { Task { await model.importConnection(data, code: model.importCode) } } } }
                }
            }
        }
        .sheet(item: $shared) { file in ShareSheet(items: [file.url]) }
        .quickLookPreview($preview)
        .alert("Samsung Cloud Notes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("Log out of \(model.account)?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { model.signOut() }
        } message: { Text("The saved connection is removed. Cached notes and drafts stay on this device.") }
        .onChange(of: model.selection) { value in Task { await model.select(value) } }
        .onChange(of: model.title) { _ in model.scheduleDraft() }
        .onChange(of: model.body) { _ in model.scheduleDraft() }
        .onChange(of: model.document?.serverID) { _ in showDrawing = model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(model.document?.drawingPages.isEmpty ?? true) }
        .onChange(of: model.folder) { _ in model.preserveDraft(); model.selection = nil }
        .onChange(of: scenePhase) { phase in if phase != .active { model.preserveDraft() } }
        .task { model.autoSelectFirst = false; await model.connect() }
    }

    private var sidebar: some View {
        List(selection: folderSelection) {
            Label("All notes", systemImage: "doc.text").tag("all")
            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders) { folder in Label(folder.name, systemImage: "folder").tag(folder.id) }
                }
            }
            Label("Trash", systemImage: "trash").tag("trash")
            Section {
                if model.account.isEmpty {
                    Button { Task { await model.signIn() } } label: { Label("Sign in with Samsung", systemImage: "person.crop.circle.badge.plus") }.disabled(model.busy)
                } else {
                    Menu {
                        Button("Log out", role: .destructive) { confirmLogout = true }
                    } label: {
                        Label { Text(model.account).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary) } icon: { Image(systemName: "person.crop.circle") }
                    }.disabled(model.busy).accessibilityHint("Account options")
                }
            } footer: { Text("Version \(appVersion) · Unofficial client") }
        }
        .navigationTitle("Cloud Notes")
    }

    private var noteList: some View {
        List(model.visibleNotes, selection: $model.selection) { note in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.locked ? "Locked note" : note.title).fontWeight(.medium).lineLimit(2)
                    if note.locked || note.encrypted { Image(systemName: "lock").foregroundStyle(.secondary) }
                }
                if !note.snippet.isEmpty { Text(note.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Text(Date(timeIntervalSince1970: note.modified / 1000), style: .date).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 2).tag(note.id)
        }
        .overlay {
            if model.visibleNotes.isEmpty {
                if model.account.isEmpty { welcome }
                else { Text(model.busy ? "Loading…" : "No notes").foregroundStyle(.secondary) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { statusBar }
        .searchable(text: $model.search, prompt: "Search notes")
        .refreshable { await model.refresh() }
        .navigationTitle(model.folder == "all" ? "All notes" : model.folder == "trash" ? "Trash" : model.folders.first { $0.id == model.folder }?.name ?? "Notes")
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Your Samsung notes, on \(ClientPlatform.model)").font(.title2).multilineTextAlignment(.center)
            Text("Sign in with your Samsung account to access your notes directly from Samsung Cloud.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Sign in with Samsung") { Task { await model.signIn() } }.buttonStyle(.borderedProminent).disabled(model.busy)
            Button("Import Windows connection…") { importing = true }.font(.footnote).disabled(model.busy)
        }.padding(24).frame(maxWidth: 380)
    }

    @ViewBuilder private var detail: some View {
        if let document = model.document {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: $model.title).font(.title2.weight(.semibold)).padding(.horizontal).padding(.vertical, 10)
                    .disabled(!model.editable || model.busy)
                Divider()
                if !document.drawingPages.isEmpty {
                    Picker("View", selection: $showDrawing) { Text("Text").tag(false); Text("Drawing").tag(true) }
                        .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                }
                if showDrawing && !document.drawingPages.isEmpty { DrawingPreview(pages: document.drawingPages) }
                else {
                    TextEditor(text: $model.body).font(.body).padding(.horizontal, 12)
                        .disabled(!model.editable || model.busy || document.bodyObject == nil)
                }
                let attachments = document.assets.filter { !$0.isInternal }
                if !attachments.isEmpty {
                    Divider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                            ForEach(attachments) { asset in
                                Button(asset.fileName) { Task { preview = await model.attachmentURL(asset) } }.buttonStyle(.bordered).lineLimit(1)
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                    }
                }
                if let issue = document.textIssue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6) }
                if model.draftConflict { Text("This local draft is based on an older cloud revision. Reload the note to archive the draft and open the current cloud copy.").font(.caption).foregroundStyle(.orange).padding(.horizontal).padding(.vertical, 6) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(model.dirty ? "Local draft" : "Cloud copy").font(.caption).foregroundStyle(model.dirty ? .orange : .secondary)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await model.save() } } label: { Label("Save to cloud", systemImage: "icloud.and.arrow.up") }
                        .disabled(model.busy || !model.dirty || !model.editable)
                    Menu {
                        Button { Task { if let id = model.selection { model.preserveDraft(); await model.open(id, force: true) } } } label: { Label("Reload cloud copy", systemImage: "arrow.down.doc") }
                        if !document.drawingPages.isEmpty { Button { preview = model.drawingURL() } label: { Label("Drawing PDF", systemImage: "doc.richtext") } }
                        Button { Task { if let url = await model.exportArchive() { shared = SharedFile(url: url) } } } label: { Label("Export original…", systemImage: "square.and.arrow.up") }
                    } label: { Label("More", systemImage: "ellipsis.circle") }.disabled(model.busy)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "note.text").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(model.account.isEmpty ? "Not signed in" : "Select a note").font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6).background(.bar)
    }
}

@main struct SamsungCloudNotesApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            let result: String
            do { try SelfTest.run(); result = "Offline self-tests passed." }
            catch { result = "Self-test failed: \(error.localizedDescription)" }
            print(result)
            // scripts/check-ios.sh reads this file: simulator console capture can
            // miss the output of a process that exits immediately.
            try? Data((result + "\n").utf8).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("self-test-result.txt"))
            exit(result == "Offline self-tests passed." ? 0 : 1)
        }
    }
    var body: some Scene { WindowGroup { NotesRootView() } }
}
