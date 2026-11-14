import Foundation

enum DraftSelfTest {
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scnotes-draft-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = NoteDraftStore(root:root), id = "draft-fixture"
        func document(_ commit: String, _ body: String) throws -> CloudDocument {
            let xml = "<CompareNoteView><noteResource id=\"fixture\"><attributes><title><object><text>\(StyledText.encode("Fixture"))</text></object></title></attributes><bodyText><object><text>\(StyledText.encode(body))</text></object></bodyText><noteTree/></noteResource><commitId>\(commit)</commitId></CompareNoteView>"
            return try CloudDocument(serverID:id,data:Data(xml.utf8))
        }
        let old = try document("old","Old cloud text"), fresh = try document("fresh","New cloud text")
        let model = NotesModel(drafts:store); model.selection = id
        model.notes = [NoteRecord(id:id,resourceID:"fixture",commit:"old",modified:0,locked:false,encrypted:false)]
        // A clean saved baseline must not become a fake draft after a remote edit.
        try store.write(NoteDraft(title:old.title,body:old.body,commit:old.commit),id:id)
        try model.present(old)
        guard try store.read(id) == nil else { throw NotesError.message("Clean saved text was retained as an unsaved draft.") }
        try model.present(fresh)
        guard !model.dirty, !model.draftConflict, model.body == fresh.body, model.notes.first?.commit == fresh.commit else { throw NotesError.message("Remote text resurrected a clean baseline draft or kept the old revision.") }
        // Clearing a stale draft works without a client, and reopening stays clean.
        let stale = NoteDraft(title:old.title,body:"Unsaved local text",commit:old.commit)
        try store.write(stale,id:id); try model.present(fresh)
        guard model.dirty, model.draftConflict else { throw NotesError.message("Stale-draft fixture did not reproduce.") }
        model.discardLocalChanges()
        guard !model.dirty, !model.draftConflict, model.body == fresh.body, try store.read(id) == nil else { throw NotesError.message("Offline discard failed to clear the stale draft.") }
        try model.present(fresh)
        guard !model.dirty, !model.draftConflict else { throw NotesError.message("Discarded draft returned on reopening.") }
        let archives = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("DraftHistory"),includingPropertiesForKeys:nil)
        guard try archives.contains(where:{ try JSONDecoder().decode(NoteDraft.self,from:Data(contentsOf:$0)) == stale }) else { throw NotesError.message("Discard did not preserve its recovery copy.") }
        // A pending debounce must not recreate the discarded active draft.
        model.body = "Not yet autosaved"; model.scheduleDraft(); model.discardLocalChanges()
        try await Task.sleep(nanoseconds:750_000_000)
        guard try store.read(id) == nil, !model.dirty, !model.draftConflict else { throw NotesError.message("A pending autosave resurrected the discarded draft.") }
        // Reload does not write another clean baseline into Drafts.
        try store.write(stale,id:id); try model.present(fresh,restoringDraft:false)
        guard try store.read(id) == nil, !model.dirty, !model.draftConflict else { throw NotesError.message("Reload retained an active draft.") }
        // Save cleanup cannot remove another writer's newer draft.
        try store.write(stale,id:id)
        try store.removeIfMatches(id,draft:NoteDraft(title:old.title,body:"different",commit:old.commit))
        guard try store.read(id) == stale else { throw NotesError.message("Save cleanup removed another local draft.") }
        try store.removeIfMatches(id,draft:stale)
        guard try store.read(id) == nil else { throw NotesError.message("Save cleanup retained the matching saved draft.") }
        // If the recovery archive cannot be written, preserve the active file and UI.
        let blocked = NoteDraftStore(root:root.appendingPathComponent("blocked"))
        try blocked.write(stale,id:id)
        try Data("not a directory".utf8).write(to:blocked.root.appendingPathComponent("DraftHistory"))
        let guarded = NotesModel(drafts:blocked); guarded.selection = id; try guarded.present(fresh)
        guarded.discardLocalChanges()
        guard try blocked.read(id) == stale, guarded.draftConflict, guarded.dirty, guarded.error != nil else { throw NotesError.message("Failed archive lost the local draft.") }
        print("Draft migration, offline discard, recovery, reopen, autosave-race, reload and save-cleanup checks passed.")
    }
}
