package local.samsungcloudnotes

import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URL
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

// Port of Sources/Shared/Cloud.swift. Keep the two in step: request headers,
// cursors, conflict checks and the readback verification are deliberately identical.

class NotesException(message: String) : Exception(message)

/** Strict UTF-8: malformed input is an error instead of replacement characters. */
fun strictUtf8(bytes: ByteArray): String? = try {
    Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()
} catch (_: Exception) { null }

fun base64Decode(value: String): ByteArray? = try { Base64.getDecoder().decode(value) } catch (_: IllegalArgumentException) { null }
fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

data class AccountSession(
    val authorization: String,
    val account: String,
    val nativeID: String? = null,
    val expiresAt: Long? = null, // epoch milliseconds
) {
    fun toJson(): String = JSONObject().apply {
        put("authorization", authorization); put("account", account)
        nativeID?.let { put("nativeID", it) }
        expiresAt?.let { put("expiresAt", it) }
    }.toString()
    companion object {
        fun fromJson(text: String): AccountSession {
            val json = JSONObject(text)
            return AccountSession(json.getString("authorization"), json.getString("account"),
                json.optString("nativeID").ifEmpty { null }, if (json.has("expiresAt")) json.getLong("expiresAt") else null)
        }
    }
}

object StyledText {
    private val marker = Regex("<\\?.*?\\?>", RegexOption.DOT_MATCHES_ALL)
    fun decode(encoded: String): String {
        if (encoded.isEmpty()) return ""
        val source = base64Decode(encoded)?.let(::strictUtf8)
            ?: throw NotesException("This text uses an unsupported encoding. Its original data has been retained.")
        val output = StringBuilder()
        var offset = 0
        for (match in marker.findAll(source)) {
            output.append(decodeRun(source.substring(offset, match.range.first)))
            offset = match.range.last + 1
        }
        output.append(decodeRun(source.substring(offset)))
        return output.toString()
    }
    private fun decodeRun(value: String): String {
        if (value.isBlank()) return ""
        val compact = value.filterNot { it.isWhitespace() }
        return base64Decode(compact)?.let(::strictUtf8)
            ?: throw NotesException("This text includes an unsupported span. Export the original document to retain it.")
    }
    fun encode(text: String): String {
        val count = text.length // UTF-16 code units, as Samsung counts them
        val header = "<?a 'paragraph/alignment'='0' 'paragraph/parsingState'='False' 'span/fontSize'='1,12' 'span/foregroundColor'='1,-14342875' 'sectionData/sectionData'='$count'?>"
        val tail = "<?a 'span/foregroundColor' 'span/fontSize' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>"
        return base64((header + base64(text.toByteArray()) + tail).toByteArray())
    }
}

data class NoteRecord(
    val id: String,
    var resourceID: String,
    var commit: String,
    val modified: Double,
    val locked: Boolean,
    val encrypted: Boolean,
    var title: String = "Untitled",
    var snippet: String = "",
    var folder: String = "",
    var trashed: Boolean = false,
) {
    /** List metadata derived from a downloaded document. */
    fun describe(document: CloudDocument) {
        val heading = document.title.trim()
        val firstLine = document.body.lineSequence().firstOrNull { it.isNotEmpty() } ?: ""
        title = heading.ifEmpty { firstLine.ifEmpty { "Untitled note" } }
        snippet = document.body.trim().take(160)
        resourceID = document.resource.attr("id")
    }
    fun toJson(): JSONObject = JSONObject().put("id", id).put("resourceID", resourceID).put("commit", commit).put("modified", modified)
        .put("locked", locked).put("encrypted", encrypted).put("title", title).put("snippet", snippet).put("folder", folder).put("trashed", trashed)
    companion object {
        fun fromJson(json: JSONObject) = NoteRecord(json.getString("id"), json.getString("resourceID"), json.getString("commit"), json.getDouble("modified"),
            json.getBoolean("locked"), json.getBoolean("encrypted"), json.optString("title", "Untitled"), json.optString("snippet"),
            json.optString("folder"), json.optBoolean("trashed"))
    }
}

data class FolderRecord(val id: String, val name: String, val parent: String)
data class CloudIndex(val notes: List<NoteRecord>, val folders: List<FolderRecord>)

fun decodedCloudName(value: String): String {
    val decoded = base64Decode(value)?.let(::strictUtf8) ?: return value
    if (decoded.isEmpty() || decoded.any { Character.getType(it) == Character.CONTROL.toInt() }) return value
    return decoded.filterNot { it == '​' || it == '﻿' }
}

data class AssetRecord(val id: String, val name: String, val url: String?) {
    val fileName: String get() = name.split("@").drop(1).joinToString("@").ifEmpty { name }
    val isInternal: Boolean get() = fileName.substringAfterLast('.', "").lowercase() in setOf("spi", "spd", "page", "dat")
}

class CloudDocument(val serverID: String, val original: ByteArray) {
    val xml = XmlDocument(original)
    val resource: XmlElement
    val commit: String
    val bodyObject: XmlElement?
    val titleObject: XmlElement?
    var body: String
    var title: String
    val assets = mutableListOf<AssetRecord>()
    val textIssue: String?
    val drawingPages: List<DrawingPage>

    init {
        val root = xml.rootElement()
        val noteResource = root?.first("noteResource")
        if (root?.name != "CompareNoteView" || noteResource == null) throw NotesException("Samsung returned an unsupported note document.")
        resource = noteResource
        commit = root.value("commitId")
        bodyObject = resource.first("bodyText")?.first("object")
        titleObject = resource.first("attributes")?.first("title")?.first("object")
        val issues = mutableListOf<String>()
        body = try { StyledText.decode(bodyObject?.value("text") ?: "") } catch (error: NotesException) { issues.add(error.message ?: ""); "" }
        title = try { StyledText.decode(titleObject?.value("text") ?: "") } catch (error: NotesException) { issues.add(error.message ?: ""); "" }
        textIssue = if (issues.isEmpty()) null else issues.joinToString(" ")
        val contentFiles = resource.first("contentFileList")?.elements("contentFile") ?: emptyList()
        val downloads = root.first("downloadUrls")
        for (download in downloads?.elements("downloadUrl") ?: emptyList()) {
            val id = download.value("id")
            val url = runCatching { URI(download.value("url")) }.getOrNull() ?: continue
            val host = url.host ?: continue
            if (url.scheme != "https" || !(host == "samsungcloud.com" || host.endsWith(".samsungcloud.com"))) continue
            val file = contentFiles.firstOrNull { it.attr("id") == id }
            assets.add(AssetRecord(id, decodedCloudName(file?.attr("name") ?: id), url.toString()))
        }
        if (downloads == null) for (file in contentFiles) assets.add(AssetRecord(file.attr("id"), decodedCloudName(file.attr("name")), null))
        drawingPages = (resource.first("pageList")?.elements("page") ?: emptyList()).mapIndexedNotNull { index, page -> DrawingPage.from(page, index) }
    }

    val locked: Boolean get() = resource.attr("isEncrypted") == "true" || resource.attr("isLocked") == "true"

    fun uploadXml(newTitle: String, newBody: String, nowMillis: Long = System.currentTimeMillis()): ByteArray {
        textIssue?.let { throw NotesException(it) }
        if (locked) throw NotesException("Locked or encrypted notes cannot be edited by this version.")
        val micros = (nowMillis * 1000).toString()
        if (body != newBody) {
            val obj = bodyObject; val text = obj?.first("text"); val tree = resource.first("noteTree")?.first("bodyText")
            if (obj == null || text == null || tree == null) throw NotesException("This note has no supported typed-text body. Its drawings are retained in the original document.")
            text.stringValue = StyledText.encode(newBody)
            obj.set("modifiedTime", micros); obj.set("timeStamp", micros)
            val digest = sha256(obj.bytes).hex()
            obj.set("hash", digest); tree.set("h", digest); tree.set("t", micros)
        }
        if (title != newTitle) {
            val obj = titleObject ?: throw NotesException("This note's title cannot be edited yet.")
            val field = obj.first("text")
            if (field != null) field.stringValue = StyledText.encode(newTitle) else obj.addChild(XmlElement("text", StyledText.encode(newTitle)))
            obj.set("modifiedTime", micros)
            obj.set("hash", sha256(obj.bytes).hex())
        }
        resource.first("attributes")?.let { attrs ->
            attrs.set("modifiedTime", micros); attrs.set("editTime", micros)
            attrs.set("displayModifiedTime", nowMillis.toString())
        }
        return resource.bytes
    }
}

class CloudClient(account: AccountSession, private val renew: suspend (AccountSession, Boolean) -> AccountSession) {
    var account = account
        private set
    private val base = "https://api.samsungcloud.com"

    suspend fun request(path: String, method: String = "GET", body: ByteArray? = null, contentType: String? = null): ByteArray = withContext(Dispatchers.IO) {
        if (!path.startsWith("/") || URL(base + path).host != "api.samsungcloud.com") throw NotesException("Invalid Samsung Cloud path.")
        if (account.nativeID != null) account = renew(account, false)
        for (attempt in 0..1) {
            val headers = mapOf(
                "Authorization" to account.authorization,
                "x-sn-sdk-ver" to "5500",
                "x-sn-app-ver" to "4000",
                "X-SN-XML-VER" to "2",
                "X-SN-Feature-ID" to "O4vARCbQ3G",
                "User-Agent" to ClientPlatform.userAgent,
                "x-sn-model-name" to base64(ClientPlatform.model.toByteArray()),
            ) + (contentType?.let { mapOf("Content-Type" to it) } ?: emptyMap())
            val (status, data) = Http.send(base + path, method, headers, body, followRedirects = true)
            if (status == 401 || status == 403) {
                if (account.nativeID != null && attempt == 0) { account = renew(account, true); continue }
                throw NotesException(if (account.nativeID == null) "This imported connection expired. Sign in with Samsung on this device." else "Samsung rejected the renewed connection. Sign in with Samsung again.")
            }
            if (status !in 200..299) {
                val message = runCatching { XmlDocument(data).rootElement()?.value("message") }.getOrNull().orEmpty()
                throw NotesException("Samsung Cloud returned $status${if (message.isEmpty()) "" else ": $message"}.")
            }
            return@withContext data
        }
        throw NotesException("Samsung could not renew the Notes connection.")
    }

    private fun query(name: String, value: String): String {
        // Matches URLComponents on Apple platforms: base64 characters stay literal.
        val encoded = StringBuilder()
        for (byte in value.toByteArray()) {
            val c = (byte.toInt() and 0xff).toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c in "-._~+/=") encoded.append(c) else encoded.append("%%%02X".format(c.code))
        }
        return "$name=$encoded"
    }

    suspend fun loadIndex(): CloudIndex {
        var cursor = initialCursor("NOTE")
        val notes = linkedMapOf<String, NoteRecord>()
        val seen = mutableSetOf<String>()
        var completed = false
        for (page in 0 until 10_000) {
            if (!seen.add(cursor)) throw NotesException("Samsung returned a repeated pagination cursor.")
            val root = XmlDocument(request("/samsungnotes/v1/notes/changes?" + query("lastChangePoint", cursor))).rootElement()
            if (root?.name != "NoteChangesView") throw NotesException("Samsung returned an unexpected note index.")
            for (change in root.elements("changes")) {
                val id = change.value("serverId")
                if (change.value("isDeleted") == "true") { notes.remove(id); continue }
                notes[id] = NoteRecord(id, change.value("resourceId"), change.value("commitId"), change.value("serverModifiedTime").toDoubleOrNull() ?: 0.0,
                    change.value("isLocked") == "true", change.value("isEncrypted") == "true")
            }
            if (root.value("hasNext") != "true") { completed = true; break }
            cursor = root.value("lastChangePoint")
            if (cursor.isEmpty()) throw NotesException("Samsung omitted the next pagination cursor.")
        }
        if (!completed) throw NotesException("The note index exceeded the pagination limit.")
        val folderXml = XmlDocument(request("/samsungnotes/v1/folder/changes?" + query("lastChangePoint", initialCursor("FOLDER"))))
        val folders = mutableListOf<FolderRecord>()
        for (node in folderXml.rootElement()?.first("folderResource")?.first("nodeList")?.elements("node") ?: emptyList()) {
            val state = node.value("state")
            if (node.attr("type") == "folder" && state == "normal") {
                folders.add(FolderRecord(node.attr("id"), decodedCloudName(node.value("name")), node.value("parentFolderNodeId")))
            } else if (node.attr("type") == "note") {
                val id = notes.values.firstOrNull { it.resourceID == node.attr("id") }?.id ?: continue
                notes[id]?.folder = node.value("parentFolderNodeId")
                notes[id]?.trashed = state == "trashed"
                if (state == "deleted") notes.remove(id)
            }
        }
        val collator = java.text.Collator.getInstance()
        return CloudIndex(notes.values.sortedByDescending { it.modified }, folders.sortedWith { a, b -> collator.compare(a.name, b.name) })
    }

    suspend fun download(id: String): CloudDocument {
        if (!Regex("^[A-Za-z0-9_-]+$").matches(id)) throw NotesException("Invalid note identifier.")
        val data = request("/samsungnotes/v1/notes/$id/compareForDownsync", "POST", "<note ver=\"1\"/>".toByteArray(), "application/xml")
        return withContext(Dispatchers.Default) { CloudDocument(id, data) }
    }

    suspend fun currentCommit(id: String): String {
        val value = XmlDocument(request("/samsungnotes/v1/notes/$id/info")).rootElement()?.attr("commitId")
        if (value.isNullOrEmpty()) throw NotesException("Samsung omitted the current revision.")
        return value
    }

    suspend fun save(document: CloudDocument, title: String, body: String): CloudDocument {
        val remoteCommit = currentCommit(document.serverID)
        if (remoteCommit != document.commit) throw NotesException("This note changed on another device. Your draft is saved locally; reload the cloud copy before saving again.")
        LocalStore.backup(document)
        val xml = document.uploadXml(title, body)
        val boundary = "SamsungNotesAndroid-" + UUID.randomUUID()
        val payload = ByteArrayOutputStream().apply {
            write("--$boundary\r\nContent-Disposition: form-data; name=\"noteResource\"\r\nContent-Type: application/xml\r\n\r\n".toByteArray())
            write(xml); write("\r\n--$boundary--\r\n".toByteArray())
        }.toByteArray()
        request("/samsungnotes/v1/notes/${document.serverID}/update", "POST", payload, "multipart/form-data; boundary=$boundary")
        val fresh = download(document.serverID)
        if (fresh.body != body || fresh.title != title) throw NotesException("Samsung accepted the upload, but its readback differs from the draft. The local draft and backup are retained.")
        return fresh
    }

    suspend fun downloadAsset(asset: AssetRecord): ByteArray = withContext(Dispatchers.IO) {
        val url = asset.url ?: throw NotesException("Reload the note to retrieve this attachment from Samsung Cloud.")
        if (account.nativeID != null) account = renew(account, false)
        val (status, data) = Http.send(url, "GET", mapOf("Authorization" to account.authorization), null, followRedirects = true)
        if (status != 200) throw NotesException("The attachment download failed. Reload the note to refresh its download URL.")
        data
    }

    companion object {
        fun initialCursor(type: String): String =
            base64("{\"appVersion\":\"0\",\"encryptedGuid\":\"\",\"modifiedTime\":0,\"purpose\":\"INITIAL\",\"requestTimeStamp\":0,\"sdkVersion\":\"0\",\"type\":\"$type\",\"version\":0}".toByteArray())
    }
}

/** Minimal HTTPS transport. Redirects stay on HTTPS and drop credentials when the host changes. */
object Http {
    fun send(address: String, method: String, headers: Map<String, String>, body: ByteArray?, followRedirects: Boolean, timeoutMillis: Int = 40_000): Pair<Int, ByteArray> {
        var url = URL(address)
        var currentHeaders = headers
        val originalHost = url.host
        repeat(6) {
            if (url.protocol != "https") throw NotesException("Refusing a non-HTTPS connection.")
            val connection = url.openConnection() as HttpsURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.connectTimeout = timeoutMillis; connection.readTimeout = timeoutMillis
                connection.requestMethod = method
                for ((name, value) in currentHeaders) connection.setRequestProperty(name, value)
                if (body != null) { connection.doOutput = true; connection.setFixedLengthStreamingMode(body.size); connection.outputStream.use { it.write(body) } }
                val status = connection.responseCode
                if (followRedirects && status in 300..399 && status != 304) {
                    val location = connection.getHeaderField("Location") ?: throw NotesException("Samsung returned a redirect without a destination.")
                    url = URL(url, location)
                    if (url.host != originalHost) currentHeaders = currentHeaders.filterKeys { !it.equals("Authorization", ignoreCase = true) }
                    return@repeat
                }
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                return status to (stream?.use { it.readBytes() } ?: ByteArray(0))
            } finally { connection.disconnect() }
        }
        throw NotesException("Too many redirects.")
    }
}
