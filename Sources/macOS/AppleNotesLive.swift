import AppKit
import Foundation

/// Automatic Apple Notes sync (1.2.0-beta.8), active once Sync with Apple Notes has set up the mirror.
/// - Edits made in Notes are read from its database while it runs (read-only, no relaunch), shown here
///   as a local draft and saved to Samsung Cloud after a minute without changes.
/// - Samsung changes (other devices, or saves here) are written into Notes as soon as Notes has been
///   quiet for a few seconds. Writing needs Notes closed for a moment; it comes back behind the current
///   app, or in front if it was.
/// - Typing a note here closes Notes, so a note is never edited in two places at once. Notes comes back
///   in the background once that edit is saved and written.
@MainActor final class AppleNotesLive: ObservableObject {
    @Published var enabled = UserDefaults.standard.object(forKey: "appleNotesAutoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "appleNotesAutoSync") }
    }
    private weak var model: NotesModel?
    private var timer: Timer?
    private let path = AppleNoteStore.defaultPath
    private var stamp: [Date?] = []
    /// Notes' database last changed (typing there), and whether that change still needs reading.
    private var storeActivity = Date.distantPast
    private var unread = false
    private var running = false
    private var writeWanted: Date?
    private var lastWrite = Date.distantPast, lastBackup = Date.distantPast
    private var pausedUntil = Date.distantPast
    /// Apple edits of notes not open here, saved after a minute without changes: id → last change seen.
    private var pending: [String: Date] = [:]
    private var closedForEditing = false, quitting = false
    private var lastLocalEdit = Date.distantPast

    func attach(_ model: NotesModel) {
        self.model = model
        model.onSaved = { [weak self] _ in self?.requestWrite() }
        model.onCloudChanges = { [weak self] in self?.requestWrite() }
        model.onLocalEdit = { [weak self] in self?.localEdit() }
        stamp = storeStamp()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    /// Set up by a first Sync with Apple Notes (the "Samsung Notes" folder exists in the mirror).
    private var active: Bool { enabled && FileManager.default.fileExists(atPath: path) && (try? AppleMirror.load(AppleMirror.url()).folder) != nil }
    /// Automatic sync is on and set up.
    var syncing: Bool { active }

    private func storeStamp() -> [Date?] {
        ["", "-wal"].map { (try? FileManager.default.attributesOfItem(atPath: path + $0))?[.modificationDate] as? Date }
    }

    private func requestWrite() { if writeWanted == nil { writeWanted = Date() } }

    private func tick() {
        guard let model, !model.account.isEmpty, active else { return }
        let now = Date()
        let current = storeStamp()
        if current != stamp { stamp = current; storeActivity = now; unread = true }
        guard !running, !quitting, !model.busy, !AppleNotesSync.inProgress, now >= pausedUntil else { return }
        // Edits made in Notes: read once it has been quiet for two seconds.
        if unread, now.timeIntervalSince(storeActivity) >= 2 {
            unread = false
            Task { await importPass() }
            return
        }
        // Samsung changes: written once Notes has been quiet for five seconds, so it never quits mid-word.
        if let wanted = writeWanted, now.timeIntervalSince(storeActivity) >= 5 || now.timeIntervalSince(wanted) >= 60 {
            Task { await writePass() }
            return
        }
        // Apple edits of notes not open here: saved after a minute without changes.
        if let id = pending.first(where: { now.timeIntervalSince($0.value) >= 60 })?.key {
            pending[id] = nil
            Task { await model.saveStoredDraft(id) }
            return
        }
        // Notes, closed while a note was typed here, comes back once that edit is saved and written.
        if closedForEditing, !model.dirty, writeWanted == nil, now.timeIntervalSince(lastLocalEdit) >= 5 {
            closedForEditing = false
            if AppleNotesSync.notesRunning.isEmpty { AppleNotesSync.openNotes(activate: false) }
        }
    }

    private func load(_ model: NotesModel) -> (AssetRecord, CloudDocument) async -> Data? {
        { [weak model] asset, document in try? await model?.attachmentData(asset, document: document) }
    }

    /// Reads Notes without closing it: edits made there become drafts here.
    private func importPass() async {
        guard let model, !running else { return }
        running = true; defer { running = false }
        // Text typed here is stored first, so an Apple edit of the same note counts as a conflict, never replaces it.
        model.preserveDraft()
        do {
            let report = try await AppleNotesSync.run(model.appleSyncItems, drafts: model.drafts, writes: false, load: load(model))
            show(report)
            // Notes that need writing (a new Samsung note, say) are written soon, but not in a loop.
            if report.pendingWrites > 0, Date().timeIntervalSince(lastWrite) >= 60 { requestWrite() }
        } catch { pause("Apple Notes could not be read: " + error.localizedDescription) }
    }

    /// Writes Samsung changes into Notes, closing it only when something must actually be written.
    private func writePass() async {
        guard let model, !running else { return }
        running = true; defer { running = false }
        writeWanted = nil; lastWrite = Date()
        model.preserveDraft()
        let items = model.appleSyncItems
        do {
            let plan = try await AppleNotesSync.run(items, drafts: model.drafts, writes: false, load: load(model))
            show(plan)
            guard plan.pendingWrites > 0 else { return }
            let backup = Date().timeIntervalSince(lastBackup) >= 600
            let report = try await AppleNotesSync.run(items, drafts: model.drafts, reopen: closedForEditing ? .never : .ifRunning,
                                                      backup: backup, load: load(model))
            if backup { lastBackup = Date() }
            stamp = storeStamp(); unread = false
            show(report)
            model.status = report.summary
        } catch { pause("Apple Notes sync paused for 5 minutes: " + error.localizedDescription) }
    }

    private func pause(_ message: String) {
        pausedUntil = Date().addingTimeInterval(300)
        model?.status = message
    }

    /// Shows Apple edits: live in the open note (unless it is being typed here), otherwise saved after a minute.
    private func show(_ report: AppleNotesSync.Report) {
        guard let model, !report.imported.isEmpty else { return }
        let now = Date()
        for id in report.imported {
            if id == model.selection {
                // Scheduled here too: with the window closed (menu bar mode) no editor reports the change.
                if !model.editingHere, let document = model.loaded[id] { try? model.present(document); model.scheduleDraft() }
            } else { pending[id] = now }
        }
        let names = report.imported.compactMap { id in model.notes.first { $0.id == id }?.title }.joined(separator: ", ")
        model.status = "Edited in Apple Notes: \(names) · saves to Samsung Cloud after a minute without changes"
    }

    /// Typing a note here closes Notes (it saves its own edits as it quits); they are read right after.
    private func localEdit() {
        lastLocalEdit = Date()
        guard active, !quitting, !AppleNotesSync.notesRunning.isEmpty else { return }
        quitting = true; closedForEditing = true
        Task {
            try? await AppleNotesSync.quitNotes()
            quitting = false
            storeActivity = .distantPast; unread = true
        }
    }

    func appWillTerminate() {
        if closedForEditing, AppleNotesSync.notesRunning.isEmpty { AppleNotesSync.openNotes(activate: false) }
    }
}
