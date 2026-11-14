package local.samsungcloudnotes.nativebridge

import java.net.URI

/** Destinations used by Samsung's native serializer and binary transfers. */
object NativeSyncPolicy {
    fun allows(address: String?, method: String?): Boolean {
        if (address == null || method == null) return false
        val uri = runCatching { URI(address) }.getOrNull() ?: return false
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.rawFragment != null || uri.port !in listOf(-1, 443)) return false
        val path = uri.path ?: return false
        if (path.split('/').any { it == "." || it == ".." } || path.any { it.code < 32 }) return false
        val host = uri.host?.lowercase() ?: return false
        if (host == "api.samsungcloud.com") {
            if (path.contains("/telemetry/")) return false
            return Regex("^/samsungnotes/v[123]/.+").matches(path) && method in setOf("GET", "HEAD", "POST", "PATCH", "PUT", "DELETE")
        }
        return method in setOf("GET", "HEAD", "PUT") &&
            (host.endsWith(".samsungcloud.com") || host.endsWith(".amazonaws.com") || host.endsWith(".cloudfront.net"))
    }
}
