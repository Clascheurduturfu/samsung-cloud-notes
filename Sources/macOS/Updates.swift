import Foundation
import SwiftUI
import AppKit

private final class NotesUpdateNetwork: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(NotesUpdateConfiguration.redirected(request))
    }
    static func fetch(_ url: URL, binary: Bool = false, limit: Int, progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> Data {
        let delegate = NotesUpdateNetwork(), config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:url)
        request.setValue(binary ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField:"Accept")
        request.setValue("SamsungCloudNotes-Updater", forHTTPHeaderField:"User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField:"X-GitHub-Api-Version")
        let (bytes,response) = try await session.bytes(for:request)
        guard let http = response as? HTTPURLResponse else { throw NotesError.message("GitHub did not return an HTTP response.") }
        try NotesUpdateHTTP.validate(status:http.statusCode,expectedLength:response.expectedContentLength,limit:limit)
        var result = Data(); result.reserveCapacity(min(limit, max(0,Int(response.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard result.count < limit else { throw NotesError.message("The update download exceeds the allowed size.") }
            result.append(byte)
            if result.count % 65536 == 0 { await progress(result.count) }
        }
        await progress(result.count); return result
    }
}

@MainActor final class NotesAppUpdates: ObservableObject {
    static let shared = NotesAppUpdates()
    @Published var channel: UpdateChannel {
        didSet {
            preferences.set(channel.rawValue,forKey:"updates.channel")
            operation = UUID(); task?.cancel(); release = nil; busy = false; status = "Check for updates in the selected channel."
        }
    }
    @Published var automaticallyCheck: Bool {
        didSet { preferences.set(automaticallyCheck,forKey:"updates.dailyCheck") }
    }
    @Published var busy = false
    @Published var installing = false
    @Published var status = "Check GitHub Releases for an app update."
    @Published var progress: Double?
    @Published var release: NotesGitHubRelease?
    private var operation = UUID()
    private var task: Task<Void,Never>?
    private var launchChecked = false
    private let preferences: UserDefaults
    private let fetchReleaseData: (URL) async throws -> Data
    let config = NotesUpdateConfiguration.current
    init(preferences: UserDefaults = .standard, fetch: ((URL) async throws -> Data)? = nil) {
        self.preferences = preferences
        channel = UpdateChannel(rawValue:preferences.string(forKey:"updates.channel") ?? "stable") ?? .stable
        automaticallyCheck = preferences.bool(forKey:"updates.dailyCheck")
        fetchReleaseData = fetch ?? { url in try await NotesUpdateNetwork.fetch(url,limit:2*1024*1024) }
    }
    var channelMessage: String {
        channel == .preview ? "Preview includes Mac previews and newer Stable releases." : "Stable offers final releases. Switching channels never downgrades this installation."
    }
    func checkAtLaunch() {
        guard !launchChecked else { return }; launchChecked = true
        guard automaticallyCheck, Date().timeIntervalSince1970 - preferences.double(forKey:"updates.lastCheck") >= 86400 else { return }
        check()
    }
    func check() {
        guard !busy, !installing else { return }
        busy = true; release = nil; status = "Checking published releases…"; progress = nil
        let stamp = NotesUpdateCheckStamp(channel:channel), id: UUID
        id = stamp.id; operation = id; let channel = channel; let config = config
        preferences.set(Date().timeIntervalSince1970,forKey:"updates.lastCheck")
        task = Task {
            defer { if operation == id { busy = false } }
            do {
                // Bounded feed: at most the first 300 releases. One rolling Preview keeps it small.
                var releases: [NotesGitHubRelease] = []
                for page in 1...3 {
                    let url = URL(string:config.apiURL.absoluteString + "&page=\(page)")!
                    let data = try await fetchReleaseData(url)
                    let batch = try JSONDecoder().decode([NotesGitHubRelease].self,from:data)
                    releases += batch; if batch.count < 100 { break }
                }
                guard stamp.accepts(operation:operation,channel:self.channel) else { return }
                release = NotesGitHubRelease.newest(releases,channel:channel,installed:appVersion,config:config)
                if let release { _ = try release.asset(config); status = "Version \(release.tag_name) is available." }
                else { status = "No newer \(channel.rawValue.capitalized) Mac release is available." }
            } catch {
                guard operation == id else { return }; release = nil
                status = (error as? URLError) != nil ? "Could not reach GitHub. Check your connection or open Releases." : error.localizedDescription
            }
        }
    }
    func install(model: NotesModel) {
        guard !busy, !installing, !model.busy, let selected = release else { return }
        let id = UUID(); operation = id; busy = true; installing = true; progress = 0
        task = Task {
            var staging: URL?; var handedOff = false; var ownsModelBusy = false
            defer {
                busy = false; installing = false; progress = nil
                if !handedOff, let staging { try? FileManager.default.removeItem(at:staging) }
            }
            do {
                let asset = try selected.asset(config)
                status = "Downloading \(selected.tag_name)…"
                let bytes = try await NotesUpdateNetwork.fetch(asset.url,binary:true,limit:asset.size) { count in
                    await MainActor.run { self.progress = Double(count)/Double(asset.size) }
                }
                guard operation == id else { throw CancellationError() }
                let stage = NotesUpdateTransaction.base.appendingPathComponent(UUID().uuidString,isDirectory:true); staging = stage
                try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let zip = stage.appendingPathComponent("update.zip"); try bytes.write(to:zip,options:.atomic)
                status = "Verifying download and publisher…"
                let config = config, current = Bundle.main.bundleURL
                let app = try await Task.detached {
                    try NotesUpdatePackage.validate(zip,asset:asset,version:selected.tag_name,config:config,stage:stage,current:current)
                }.value
                // Recheck at the handoff; a sync or sign-in may have started during download.
                guard operation == id, !model.busy else { throw NotesError.message("Finish the current save, sync or sign-in, then install the update.") }
                guard current.pathExtension == "app", FileManager.default.isWritableFile(atPath:current.deletingLastPathComponent().path) else { throw NotesError.message("Move the app to a writable Applications folder, or install the package manually from Releases.") }
                if let document = model.document, model.dirty, !model.draftConflict {
                    try LocalStore.writeDraft(id:document.serverID,title:model.title,body:model.body,commit:document.commit)
                }
                let transaction = NotesUpdateTransaction(stage:stage,source:app,target:current,parentPID:ProcessInfo.processInfo.processIdentifier,nonce:UUID().uuidString,version:UpdateVersion(selected.tag_name)!.normalized,probe:false)
                try transaction.validatePaths()
                let file = stage.appendingPathComponent("transaction.json")
                try JSONEncoder().encode(transaction).write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                let helper = stage.appendingPathComponent("UpdateInstaller")
                try FileManager.default.copyItem(at:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/UpdateInstaller"),to:helper)
                let p = Process(); p.executableURL = helper; p.arguments = [file.path]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                model.busy = true; ownsModelBusy = true; try p.run(); handedOff = true
                NSApplication.shared.terminate(nil)
            } catch { if ownsModelBusy { model.busy = false }; status = error.localizedDescription }
        }
    }
}

enum NotesUpdateReadiness {
    static func acknowledge() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of:"--update-transaction"), i+1 < args.count else { return }
        do {
            let file = URL(fileURLWithPath:args[i+1])
            let transaction = try JSONDecoder().decode(NotesUpdateTransaction.self,from:Data(contentsOf:file))
            try transaction.validatePaths()
            guard file.standardizedFileURL.path == transaction.stage.appendingPathComponent("transaction.json").path,
                  Bundle.main.bundleURL.resolvingSymlinksInPath().path == transaction.target.resolvingSymlinksInPath().path,
                  appVersion == transaction.version else { return }
            let data = try JSONSerialization.data(withJSONObject:["nonce":transaction.nonce,"version":appVersion,"pid":ProcessInfo.processInfo.processIdentifier])
            try data.write(to:transaction.stage.appendingPathComponent("ready.json"),options:.atomic)
        } catch { /* No acknowledgement makes the installer retain or restore the previous app. */ }
    }
}

struct NotesUpdatesView: View {
    @ObservedObject var updates: NotesAppUpdates
    @ObservedObject var model: NotesModel
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("App updates").font(.headline)
            Text("Installed: \(appVersion)").foregroundStyle(.secondary)
            Picker("Channel",selection:$updates.channel) {
                Text("Stable").tag(UpdateChannel.stable); Text("Preview").tag(UpdateChannel.preview)
            }.pickerStyle(.segmented).disabled(updates.installing)
            Text(updates.status).font(.callout).fixedSize(horizontal:false,vertical:true)
            if let value = updates.progress { ProgressView(value:value) }
            HStack {
                Button("Check for Updates") { updates.check() }.disabled(updates.busy)
                if updates.release != nil {
                    Button("Install & Restart") { updates.install(model:model) }.disabled(updates.busy || model.busy)
                }
                if updates.busy && updates.progress == nil { ProgressView().controlSize(.small) }
            }
            Toggle("Check at launch, at most once a day",isOn:$updates.automaticallyCheck).disabled(updates.installing)
            Link("Open GitHub Releases",destination:updates.config.releasesURL)
            Text(updates.channelMessage).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width:440)
    }
}
