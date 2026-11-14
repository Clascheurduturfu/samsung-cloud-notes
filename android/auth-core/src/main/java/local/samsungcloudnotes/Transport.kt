package local.samsungcloudnotes

import java.net.URL
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject

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
