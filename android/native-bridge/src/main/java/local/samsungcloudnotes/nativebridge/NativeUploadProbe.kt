package local.samsungcloudnotes.nativebridge

import android.content.Context
import android.util.Log
import java.net.URI

/** Local validation of creating one owned test note. Disabled in normal builds. */
object NativeUploadProbe {
    @Volatile private var active = false
    @Volatile private var attempted = false
    @Volatile private var folderRegistrationThread: Thread? = null

    fun allows(address: String?, method: String?): Boolean = active && (permitsCreateTransfer(address, method) ||
        (folderRegistrationThread === Thread.currentThread() && method == "PATCH" &&
            address in setOf("https://api.samsungcloud.com/samsungnotes/v1/folder", "https://api.samsungcloud.com/samsungnotes/v3/folder")))

    internal fun permitsCreateTransfer(address: String?, method: String?): Boolean {
        val uri = runCatching { URI(address ?: "") }.getOrNull() ?: return false
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.rawFragment != null || uri.port !in listOf(-1, 443)) return false
        val host = uri.host?.lowercase() ?: return false
        val path = uri.path ?: return false
        if (path.split('/').any { it == "." || it == ".." }) return false
        if (host == "api.samsungcloud.com") return method == "POST" && (
            Regex("^/samsungnotes/v[13]/notes$").matches(path) ||
            Regex("^/samsungnotes/v[23]/binaries/createUploadURLs$").matches(path))
        return method == "PUT" && (host.endsWith(".samsungcloud.com") || host.endsWith(".amazonaws.com") || host.endsWith(".cloudfront.net"))
    }

    @Synchronized fun run(context: Context, nativeTask: Any) {
        val uuid = BuildConfig.UPLOAD_PROBE_UUID
        if (uuid.isEmpty() || attempted) return
        // Inspect the native local record before enabling any creation request.
        val recordType = Class.forName("com.samsung.android.app.notes.sync.db.t")
        val record = recordType.getConstructor(Context::class.java, String::class.java).newInstance(context, uuid)
        val entity = recordType.getField("a").get(record) ?: return
        require(entity.javaClass.getMethod("getTitle").invoke(entity) == "SCN_Native_Beta_1") { "Probe requires its owned test note." }
        require((recordType.getMethod("h").invoke(record) as String?).isNullOrEmpty()) { "Probe refuses a note already present on the server." }
        require(recordType.getMethod("e").invoke(record) != 1) { "Probe refuses deleted notes." }
        require(recordType.getMethod("f").invoke(record) == 1) { "Probe requires a pending local note." }
        attempted = true
        active = true
        try {
            Log.i("SCNotesCloudBeta", "Starting isolated native test-note creation; existing-note updates and deletion remain blocked.")
            registerOwnedNoteNode(context, nativeTask, uuid)
            nativeTask.javaClass.getMethod("m", String::class.java).invoke(nativeTask, uuid)
            Log.i("SCNotesCloudBeta", "Native test-note creation returned; independent cloud verification is required.")
        } finally { active = false }
    }

    private fun registerOwnedNoteNode(context: Context, task: Any, uuid: String) {
        val info = task.javaClass.getField("a").get(task)
        val infoType = Class.forName("e4.c")
        val repositoryHolder = infoType.getField("i").get(info)
        val repository = repositoryHolder.javaClass.getField("b").get(repositoryHolder)
        val nodes = repository.javaClass.getMethod("getDirtyFolderNodeItemList").invoke(repository) as List<*>
        val node = nodes.filterNotNull().single { it.javaClass.getField("uUid").get(it) == uuid }
        val nodeType = node.javaClass
        val predefined = Class.forName("com.samsung.android.support.senl.nt.data.common.constants.PredefinedCategory")
        val uncategorized = predefined.getField("UNCATEGORIZED").get(null)
        val parent = predefined.getMethod("getUuid").invoke(uncategorized)
        require(nodeType.getField("categoryUuid").get(node) == parent) { "Probe only creates a note in the unfiled root." }
        require(nodeType.getField("isDeleted").getInt(node) == 0 && !nodeType.getField("deleted").getBoolean(node))
        nodeType.getField("parentFolderNodeId").set(node, "root")
        nodeType.getField("type").set(node, "note")
        nodeType.getField("state").set(node, "normal")
        nodeType.getField("restorePath").set(node, "")
        val singleNode = arrayListOf(node)
        val resource = Class.forName("i2.i").getConstructor(java.util.ArrayList::class.java, infoType).newInstance(singleNode, info)
        val profileType = Class.forName("f4.a")
        val profile = profileType.getConstructor().newInstance()
        val manager = infoType.getField("h").get(info)
        val requestType = Class.forName("x3.a")
        val request = requestType.getConstructor(manager.javaClass, Context::class.java, profileType, Any::class.java)
            .newInstance(manager, context, profile, resource)
        folderRegistrationThread = Thread.currentThread()
        try { requestType.getMethod("d").invoke(request) }
        finally { folderRegistrationThread = null }
        val folderTaskType = Class.forName("c4.d")
        val operation = task.javaClass.getField("b").get(task)
        val contact = task.javaClass.getField("d").get(task)
        val folderTask = folderTaskType.getConstructor(infoType, Class.forName("e4.f"), Class.forName("w3.a"))
            .newInstance(info, operation, contact)
        folderTaskType.getMethod("f", java.util.ArrayList::class.java).invoke(folderTask, singleNode)
        Log.i("SCNotesCloudBeta", "Registered the single owned test-note node; other folder metadata was not uploaded.")
    }
}
