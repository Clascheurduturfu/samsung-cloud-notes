package local.samsungcloudnotes.nativebridge

import java.net.URI

/** Server-side mutations remain blocked while native downsync is exercised. */
object NativeReadPolicy {
    fun allows(address: String?, method: String?): Boolean {
        if (address == null || method == null) return false
        val uri = runCatching { URI(address) }.getOrNull() ?: return false
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.rawFragment != null || uri.port !in listOf(-1, 443)) return false
        val host = uri.host?.lowercase() ?: return false
        val path = uri.path ?: return false
        if (path.split('/').any { it == "." || it == ".." } || path.any { it.code < 32 }) return false
        if (host == "api.samsungcloud.com") {
            if (!Regex("^/samsungnotes/v[13]/.*").matches(path)) return false
            if (path.split('/').any { it.lowercase() in setOf("delete", "create", "update", "move", "rename", "trash", "restore", "commit", "upload") }) return false
            if (method in setOf("GET", "HEAD")) return true
            // This operation prepares a download; it does not edit the note.
            val readPreparation = Regex("^/samsungnotes/v[13]/notes/[A-Za-z0-9_-]+/(prepareForDownsync|compareForDownsync)$").matches(path)
            val batchRead = Regex("^/samsungnotes/v[13]/notes/list$").matches(path)
            return method == "POST" && (readPreparation || batchRead)
        }
        val downloadHost = host.endsWith(".samsungcloud.com") || host.endsWith(".amazonaws.com") || host.endsWith(".cloudfront.net")
        return downloadHost && method in setOf("GET", "HEAD")
    }
}
