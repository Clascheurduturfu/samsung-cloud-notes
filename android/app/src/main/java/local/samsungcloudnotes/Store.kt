package local.samsungcloudnotes

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

/**
 * Credentials are sealed with a non-exportable AES-GCM key in Android Keystore
 * and kept in no-backup app storage, so they never leave this device.
 */
object CredentialVault {
    private const val KEY_ALIAS = "local.samsung-cloud-notes.credentials"
    private val services = setOf("local.samsung-cloud-notes.session", "local.samsung-cloud-notes.native-auth")
    lateinit var directory: File

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return generator.generateKey()
    }
    private fun file(service: String): File {
        require(service in services) { "Unknown credential service." }
        return File(directory, "$service.bin")
    }
    @Synchronized fun save(service: String, plain: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.doFinal(plain.toByteArray())
        directory.mkdirs()
        val target = file(service)
        val temporary = File(directory, target.name + ".tmp")
        temporary.writeBytes(byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + sealed)
        if (!temporary.renameTo(target)) throw NotesException("Could not store the Samsung connection.")
    }
    @Synchronized fun load(service: String): String? {
        val target = file(service)
        if (!target.exists()) return null
        val data = target.readBytes()
        val length = data.firstOrNull()?.toInt() ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 1, length))
            String(cipher.doFinal(data, 1 + length, data.size - 1 - length))
        } catch (_: Exception) {
            throw NotesException("The saved Samsung connection could not be unlocked. Sign in with Samsung again.")
        }
    }
    @Synchronized fun delete(service: String) { file(service).delete() }
}

object SessionStore {
    private const val SERVICE = "local.samsung-cloud-notes.session"
    fun save(value: AccountSession) {
        if (!value.authorization.startsWith("Bearer ") || value.authorization.length <= 30 || value.authorization.any { it == '\n' || it == '\r' }) {
            throw NotesException("This connection does not contain a valid Samsung session.")
        }
        CredentialVault.save(SERVICE, value.toJson())
    }
    fun loadOrNull(): AccountSession? = CredentialVault.load(SERVICE)?.let(AccountSession::fromJson)
    fun load(): AccountSession = loadOrNull() ?: throw NotesException("Sign in with Samsung to get started.")
    fun delete() = CredentialVault.delete(SERVICE)
}

object NativeAuthStore {
    private const val SERVICE = "local.samsung-cloud-notes.native-auth"
    fun save(value: NativeCredentials) = CredentialVault.save(SERVICE, value.toJson())
    fun loadOrNull(): NativeCredentials? = CredentialVault.load(SERVICE)?.let(NativeCredentials::fromJson)
    fun load(): NativeCredentials = loadOrNull() ?: throw NotesException("Sign in with Samsung to get started.")
    fun delete() = CredentialVault.delete(SERVICE)
}

/** Private, app-sandboxed copies: cache, drafts, draft history and pre-save backups. */
object LocalStore {
    lateinit var root: File
    fun init(context: Context) {
        root = File(context.filesDir, "SamsungCloudNotes")
        CredentialVault.directory = File(context.noBackupFilesDir, "credentials")
    }
    fun directory(name: String): File = File(root, name).also { if (!it.isDirectory && !it.mkdirs()) throw NotesException("Could not create local storage.") }
    private fun atomicWrite(target: File, data: ByteArray) {
        val temporary = File(target.parentFile, target.name + ".tmp")
        temporary.writeBytes(data)
        if (!temporary.renameTo(target)) { target.delete(); if (!temporary.renameTo(target)) throw NotesException("Could not write ${target.name}.") }
    }
    fun write(target: File, data: ByteArray) = atomicWrite(target, data)
    fun backup(document: CloudDocument) = atomicWrite(File(directory("Backups"), "${document.serverID}-${System.currentTimeMillis()}.xml"), document.original)
    fun writeDraft(id: String, title: String, body: String, commit: String) =
        atomicWrite(File(directory("Drafts"), "$id.json"), JSONObject().put("title", title).put("body", body).put("commit", commit).toString().toByteArray())
    data class Draft(val title: String, val body: String, val commit: String)
    fun readDraft(id: String): Draft? = runCatching {
        val json = JSONObject(File(directory("Drafts"), "$id.json").readText())
        Draft(json.getString("title"), json.getString("body"), json.optString("commit"))
    }.getOrNull()
    fun archiveDraft(id: String) {
        val source = File(directory("Drafts"), "$id.json")
        if (!source.exists()) return
        atomicWrite(File(directory("DraftHistory"), "$id-${System.currentTimeMillis()}.json"), source.readBytes())
    }
}

/** Session-scoped, revision-checked document cache. Credentials are never written here. */
class NoteCache(session: AccountSession, base: File = File(LocalStore.root, "Cache")) {
    data class Snapshot(val updated: Long, val index: CloudIndex)
    // Native sign-ins keep their cache across token renewal; imported sessions are separated by token.
    val root = File(base, key(session.nativeID ?: session.authorization)).also { it.mkdirs() }

    private fun url(key: String, kind: String) = File(root, "$kind-${key(key)}")
    fun snapshot(): Snapshot? = runCatching {
        val json = JSONObject(File(root, "index.json").readText())
        if (json.getInt("version") != 1) return null
        val index = json.getJSONObject("index")
        val notes = index.getJSONArray("notes").let { array -> (0 until array.length()).map { NoteRecord.fromJson(array.getJSONObject(it)) } }
        val folders = index.getJSONArray("folders").let { array -> (0 until array.length()).map { array.getJSONObject(it).let { f -> FolderRecord(f.getString("id"), f.getString("name"), f.getString("parent")) } } }
        Snapshot(json.getLong("updated"), CloudIndex(notes, folders))
    }.getOrNull()
    fun saveIndex(index: CloudIndex, updated: Long = System.currentTimeMillis()) {
        val json = JSONObject().put("version", 1).put("updated", updated).put("index", JSONObject()
            .put("notes", JSONArray(index.notes.map { it.toJson() }))
            .put("folders", JSONArray(index.folders.map { JSONObject().put("id", it.id).put("name", it.name).put("parent", it.parent) })))
        LocalStore.write(File(root, "index.json"), json.toString().toByteArray())
    }
    fun document(record: NoteRecord): CloudDocument? {
        if (record.locked || record.encrypted) return null
        return runCatching {
            val entry = JSONObject(url(record.id, "note").readText())
            if (entry.getString("revision") != record.commit) return null
            CloudDocument(record.id, base64Decode(entry.getString("xml")) ?: return null)
        }.getOrNull()
    }
    fun save(document: CloudDocument, revision: String) {
        val xml = XmlDocument(document.original)
        // Signed download URLs expire and may carry access parameters; keep only document data.
        xml.rootElement()?.first("downloadUrls")?.detach()
        LocalStore.write(url(document.serverID, "note"), JSONObject().put("revision", revision).put("xml", base64(xml.bytes)).toString().toByteArray())
    }
    fun asset(id: String, revision: String): ByteArray? = url("$id:$revision", "asset").takeIf { it.exists() }?.readBytes()
    fun saveAsset(data: ByteArray, id: String, revision: String) = LocalStore.write(url("$id:$revision", "asset"), data)
    fun prune(records: List<NoteRecord>) {
        val keep = records.filter { !it.locked && !it.encrypted }.map { url(it.id, "note").name }.toSet()
        root.listFiles()?.filter { it.name.startsWith("note-") && it.name !in keep }?.forEach { it.delete() }
    }
    companion object { private fun key(value: String) = sha256(value.toByteArray()).hex() }
}
