package local.samsungcloudnotes

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.io.File
import java.io.OutputStream
import java.text.DateFormat
import java.util.Date
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Port of NotesModel in Sources/Shared/Model.swift. */
class NotesViewModel(application: Application) : AndroidViewModel(application) {
    var notes by mutableStateOf(listOf<NoteRecord>()); private set
    var folders by mutableStateOf(listOf<FolderRecord>()); private set
    var selection by mutableStateOf<String?>(null); private set
    var folder by mutableStateOf("all"); private set
    var search by mutableStateOf("")
    var title by mutableStateOf("")
    var body by mutableStateOf("")
    var status by mutableStateOf("Connect your Samsung account to load your notes."); private set
    var busy by mutableStateOf(false); private set
    var draftConflict by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)
    var account by mutableStateOf(""); private set
    var document by mutableStateOf<CloudDocument?>(null); private set

    private var client: CloudClient? = null
    private var cache: NoteCache? = null
    private var loaded = mutableMapOf<String, CloudDocument>()
    private var generation = 0
    private var draftJob: Job? = null

    val dirty: Boolean get() = document?.let { it.title != title || it.body != body } ?: false
    val visibleNotes: List<NoteRecord> get() = notes.filter { note ->
        val inFolder = when (folder) { "all" -> !note.trashed; "trash" -> note.trashed; else -> note.folder == folder && !note.trashed }
        inFolder && (search.isEmpty() || "${note.title} ${note.snippet}".contains(search, ignoreCase = true))
    }
    val editable: Boolean get() {
        val doc = document ?: return false
        return !doc.locked && doc.textIssue == null && folder != "trash" && !draftConflict
    }
    val folderTitle: String get() = when (folder) { "all" -> "All notes"; "trash" -> "Trash"; else -> folders.firstOrNull { it.id == folder }?.name ?: "Notes" }

    private fun newClient(session: AccountSession) = CloudClient(session) { current, force -> SamsungSignIn.renew(current, force) }

    init { viewModelScope.launch { connect() } }

    suspend fun connect(cacheOnly: Boolean = false) {
        try {
            val session = withContext(Dispatchers.IO) { SessionStore.loadOrNull() } ?: run { status = "Sign in with Samsung to get started."; return }
            preserveDraft()
            client = newClient(session); account = session.account
            loaded = mutableMapOf(); document = null; selection = null; notes = emptyList(); folders = emptyList()
            cache = withContext(Dispatchers.IO) { NoteCache(session) }
            restoreCache()
            if (!cacheOnly) refresh()
        } catch (error: Exception) { status = error.message ?: "Could not open the saved connection." }
    }

    fun signIn() = viewModelScope.launch {
        if (busy) return@launch
        busy = true; preserveDraft()
        try {
            val saved = withContext(Dispatchers.IO) { NativeAuthStore.loadOrNull() }
            val credentials = if (saved != null) { status = "Connecting your saved Samsung sign-in…"; saved } else SamsungSignIn.signIn { status = it }
            val session = try { SamsungSignIn.cloudSession(credentials) } catch (error: SamsungHttpException) {
                if (!error.path.startsWith("/auth/oauth2/") || error.status !in setOf(400, 401, 403)) throw error
                status = "Samsung needs a new browser sign-in…"
                SamsungSignIn.cloudSession(SamsungSignIn.signIn { status = it })
            }
            status = "Checking Notes access…"
            newClient(session).loadIndex()
            withContext(Dispatchers.IO) { SessionStore.save(session) }
            busy = false
            connect()
        } catch (cancelled: CancellationException) {
            busy = false; throw cancelled
        } catch (failure: Exception) {
            busy = false; error = failure.message; status = "Samsung sign-in did not finish. Your existing notes and local drafts are retained."
        }
    }

    fun signOut() {
        if (busy) return
        try {
            document?.let { if (dirty && !draftConflict) LocalStore.writeDraft(it.serverID, title, body, it.commit) }
            SamsungSignIn.signOut()
            generation++
            draftJob?.cancel(); draftJob = null
            client = null; cache = null; loaded = mutableMapOf()
            document = null; selection = null; notes = emptyList(); folders = emptyList()
            title = ""; body = ""; account = ""; folder = "all"; search = ""
            draftConflict = false; error = null
            status = "Signed out. Sign in with Samsung to load your notes."
        } catch (failure: Exception) { error = "Could not log out: ${failure.message}" }
    }

    private suspend fun restoreCache() {
        val current = cache ?: return
        val snapshot = withContext(Dispatchers.IO) { current.snapshot() } ?: return
        val documents = withContext(Dispatchers.Default) { snapshot.index.notes.mapNotNull { record -> current.document(record)?.let { record.id to it } }.toMap() }
        loaded.putAll(documents)
        notes = snapshot.index.notes; folders = snapshot.index.folders
        status = "Cached notes · Last synced " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(snapshot.updated))
    }

    fun requestRefresh() = viewModelScope.launch { refresh() }

    suspend fun refresh() {
        val client = client ?: return
        if (busy) return
        preserveDraft()
        busy = true
        status = if (notes.isEmpty()) "Reading Samsung Cloud…" else "Checking Samsung Cloud for changes…"
        try {
            val previous = notes.associate { it.id to it.commit }
            val index = client.loadIndex()
            val records = index.notes.map { it.copy() }
            val allowed = records.filter { !it.locked && !it.encrypted }.map { it.id }.toSet()
            loaded = loaded.filterKeys { it in allowed }.toMutableMap()
            var failures = 0
            for (record in records) {
                if (record.locked || record.encrypted) continue
                var doc: CloudDocument? = null
                val existing = loaded[record.id]
                if (previous[record.id] == record.commit && existing != null) doc = existing
                else {
                    val cached = withContext(Dispatchers.Default) { cache?.document(record) }
                    if (cached != null) { doc = cached; loaded[record.id] = cached }
                    else try {
                        val fresh = client.download(record.id)
                        loaded[record.id] = fresh; doc = fresh
                        withContext(Dispatchers.IO) { cache?.save(fresh, record.commit) }
                    } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) {
                        // Never label an old document as matching a new revision.
                        loaded.remove(record.id); failures++
                    }
                }
                doc?.let { record.describe(it) }
            }
            notes = records; folders = index.folders
            withContext(Dispatchers.IO) { cache?.prune(records); cache?.saveIndex(CloudIndex(records, index.folders)) }
            selection?.let { id -> if (records.none { it.id == id && !it.locked && !it.encrypted }) { selection = null; document = null } }
            // A local draft keeps its original cloud baseline for conflict checks.
            selection?.let { if (!dirty) open(it) }
            status = "${records.count { !it.trashed }} notes · Updated ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date())}"
            if (failures > 0) status += " · $failures notes could not be downloaded"
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: SamsungHttpException) {
            status = if (failure.path.startsWith("/auth/oauth2/") && failure.status in setOf(400, 401, 403))
                "Samsung sign-in expired · Cached notes and drafts retained. Sign in with Samsung to reconnect."
            else offlineStatus(failure)
        } catch (failure: Exception) { status = offlineStatus(failure) }
        finally { busy = false }
    }
    private fun offlineStatus(failure: Exception): String {
        if (notes.isEmpty()) error = failure.message
        return if (notes.isEmpty()) "Could not reach Samsung Cloud. Pull to refresh." else "Offline · Showing cached notes and local drafts. Pull to refresh to reconnect."
    }

    fun chooseFolder(id: String) { preserveDraft(); folder = id; selection = null; document = null }

    fun select(id: String?) = viewModelScope.launch {
        preserveDraft()
        selection = id
        if (id != null) open(id) else document = null
    }

    fun reload() = viewModelScope.launch { selection?.let { preserveDraft(); open(it, force = true) } }

    private suspend fun open(id: String, force: Boolean = false) {
        val client = client ?: return
        generation++; val taskGeneration = generation
        try {
            val doc = loaded[id].takeIf { !force } ?: client.download(id).also { fresh ->
                loaded[id] = fresh
                notes.firstOrNull { it.id == id }?.let { record -> withContext(Dispatchers.IO) { cache?.save(fresh, record.commit) } }
            }
            if (generation != taskGeneration || selection != id) return
            document = doc; title = doc.title; body = doc.body; draftConflict = false
            if (force) withContext(Dispatchers.IO) { LocalStore.archiveDraft(id); LocalStore.writeDraft(id, doc.title, doc.body, doc.commit) }
            val draft = if (force) null else withContext(Dispatchers.IO) { LocalStore.readDraft(id) }
            if (draft != null && (draft.body != doc.body || draft.title != doc.title)) {
                title = draft.title; body = draft.body
                draftConflict = draft.commit != doc.commit
                status = if (draftConflict) "Draft is based on an older revision. Reload to archive it and use the cloud copy." else "Recovered an unsaved local draft. Save when ready."
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { if (generation == taskGeneration && selection == id) error = failure.message }
    }

    fun preserveDraft() {
        val doc = document ?: return
        if (!dirty || draftConflict) return
        try { LocalStore.writeDraft(doc.serverID, title, body, doc.commit) } catch (failure: Exception) { error = "Could not save your local draft: ${failure.message}" }
    }

    fun edit(newTitle: String? = null, newBody: String? = null) {
        newTitle?.let { title = it }; newBody?.let { body = it }
        draftJob?.cancel()
        draftJob = viewModelScope.launch { delay(600); preserveDraft() }
    }

    fun save() = viewModelScope.launch {
        val client = client ?: return@launch
        val doc = document ?: return@launch
        if (busy || !dirty || draftConflict) return@launch
        preserveDraft(); busy = true; status = "Saving to Samsung Cloud…"
        val id = doc.serverID; val savedTitle = title; val savedBody = body
        try {
            // Use a fresh object so a failed upload cannot mutate the displayed baseline.
            val copy = withContext(Dispatchers.Default) { CloudDocument(id, doc.original) }
            val fresh = client.save(copy, savedTitle, savedBody)
            loaded[id] = fresh
            notes = notes.map { if (it.id == id) it.copy(commit = fresh.commit).also { record -> record.describe(fresh) } else it }
            withContext(Dispatchers.IO) {
                cache?.save(fresh, fresh.commit)
                LocalStore.writeDraft(id, savedTitle, savedBody, fresh.commit)
                cache?.saveIndex(CloudIndex(notes, folders))
            }
            if (selection == id) { document = fresh; title = fresh.title; body = fresh.body }
            status = "Saved to Samsung Cloud · ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date())}"
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message; status = "Save failed. Your local draft is retained." }
        finally { busy = false }
    }

    private suspend fun attachmentData(asset: AssetRecord, doc: CloudDocument): ByteArray {
        withContext(Dispatchers.IO) { cache?.asset(asset.id, doc.commit) }?.let { return it }
        val client = client ?: throw NotesException("Connect to Samsung Cloud to download this attachment.")
        // Cached XML deliberately omits expiring signed download URLs.
        var current = asset
        if (current.url == null) {
            val fresh = client.download(doc.serverID)
            current = fresh.assets.firstOrNull { it.id == asset.id }?.takeIf { fresh.commit == doc.commit }
                ?: throw NotesException("This note changed. Refresh its cloud copy to open the attachment.")
        }
        val data = client.downloadAsset(current)
        withContext(Dispatchers.IO) { cache?.saveAsset(data, asset.id, doc.commit) }
        return data
    }

    /** Writes an attachment to the shareable cache directory; returns it with a MIME type. */
    suspend fun attachmentFile(asset: AssetRecord): Pair<File, String>? {
        val doc = document ?: return null
        return try {
            if (asset.isInternal) throw NotesException("This is an internal Samsung page resource. Use the drawing preview or export the original document.")
            val data = attachmentData(asset, doc)
            val (ext, mime) = when {
                data.startsWith(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47)) -> "png" to "image/png"
                data.startsWith(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte())) -> "jpg" to "image/jpeg"
                data.startsWith("%PDF".toByteArray()) -> "pdf" to "application/pdf"
                else -> {
                    val suffix = asset.fileName.substringAfterLast('.', "").lowercase()
                    val type = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(suffix)
                        ?: throw NotesException("This Samsung resource has no supported preview. Export the original document to keep it.")
                    suffix to type
                }
            }
            val file = File(sharedDirectory(), "${safeName(asset.fileName.substringBeforeLast('.'))}-${safeName(asset.id)}.$ext")
            withContext(Dispatchers.IO) { file.writeBytes(data) }
            file to mime
        } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) { error = failure.message; null }
    }

    suspend fun drawingFile(): File? {
        val doc = document ?: return null
        return try {
            withContext(Dispatchers.Default) { File(sharedDirectory(), safeName(doc.serverID) + ".pdf").also { it.writeBytes(DrawingPage.pdf(doc.drawingPages)) } }
        } catch (failure: Exception) { error = failure.message; null }
    }

    val exportName: String get() = safeName(title.ifEmpty { "Samsung note" }) + ".samsungnote.zip"

    /** The Mac `.samsungnote` layout (document.xml, text.txt, attachments), zipped. */
    fun export(output: () -> OutputStream?) = viewModelScope.launch {
        val doc = document ?: return@launch
        busy = true
        try {
            val attachments = doc.assets.map { safeName(it.id) to attachmentData(it, doc) }
            withContext(Dispatchers.IO) {
                ZipOutputStream(output() ?: throw NotesException("Could not open the export destination.")).use { zip ->
                    val folder = safeName(title.ifEmpty { "Samsung note" }) + ".samsungnote/"
                    fun entry(name: String, data: ByteArray) { zip.putNextEntry(ZipEntry(folder + name)); zip.write(data); zip.closeEntry() }
                    entry("document.xml", doc.original)
                    entry("text.txt", body.toByteArray())
                    attachments.forEach { (name, data) -> entry(name, data) }
                }
            }
            status = "Exported original document and ${doc.assets.size} attachments."
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = "Export did not finish: ${failure.message}" }
        finally { busy = false }
    }

    private fun sharedDirectory() = File(getApplication<Application>().cacheDir, "shared").also { it.mkdirs() }

    private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

    companion object {
        fun safeName(value: String): String {
            val result = value.map { if (it.isLetterOrDigit() || it in " -_.") it else '_' }.joinToString("").take(100)
            return result.trim().ifEmpty { "note" }
        }
    }
}
