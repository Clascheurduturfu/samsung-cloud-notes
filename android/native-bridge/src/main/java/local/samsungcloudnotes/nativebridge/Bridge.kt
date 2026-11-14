package local.samsungcloudnotes.nativebridge

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.util.Xml
import java.io.ByteArrayInputStream
import java.io.File
import java.lang.ref.WeakReference
import java.util.Locale
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import local.samsungcloudnotes.*

/** The native editor remains Samsung's. This supplies the account/cloud boundary only. */
object NotesBridge {
    const val version = "1.2.0-beta.3+5"
    private lateinit var context: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val refresh = Mutex()
    private var browser: CompletableDeferred<String>? = null
    private var activity: WeakReference<AccountActivity>? = null
    private var accountJob: Job? = null
    private var syncJob: Job? = null
    private var syncCompletion: CompletableDeferred<Int>? = null
    @Volatile private var signingOut = false
    @Volatile private var credentials: NativeCredentials? = null
    @Volatile private var expired = false
    // The native request factory is patched to enforce NativeReadPolicy before
    // any note request is created, including streaming transfers.
    private const val NATIVE_READ_ENABLED = true
    @Volatile var nativeReads = 0
        private set
    @Volatile var blockedWrites = 0
        private set

    @JvmStatic fun init(app: Context) {
        context = app.applicationContext
        // The read-only beta runs native sync only from its explicit download
        // action, after the normal Notes screen has initialized its contracts.
        CredentialVault.directory = File(context.noBackupFilesDir, "cloud-beta-credentials")
        credentials = runCatching { NativeAuthStore.loadOrNull()?.also { bindAccount(it) } }.getOrNull()
        if (isNativeReadOnly()) context.getSharedPreferences("Settings", Context.MODE_PRIVATE)
            .edit().putBoolean("settings_sync_notes", false).commit()
        SamsungSignIn.browser = { url ->
            withContext(Dispatchers.Main) {
                val host = activity?.get() ?: throw NotesException("Open Settings > Samsung Cloud to sign in.")
                browser?.cancel()
                val pending = CompletableDeferred<String>()
                browser = pending
                try {
                    host.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    withTimeout(900_000) { pending.await() }
                } finally { if (browser === pending) browser = null }
            }
        }
    }

    @JvmStatic fun isSignedIn(): Boolean = credentials != null
    @JvmStatic fun isNativeReadOnly(): Boolean = signingOut || !isSignedIn() ||
        !context.getSharedPreferences("CloudBridge", Context.MODE_PRIVATE).getBoolean("twoWaySync", false)

    private fun bindAccount(value: NativeCredentials) {
        val prefs = context.getSharedPreferences("CloudBridge", Context.MODE_PRIVATE)
        val identity = sha256(value.userID.toByteArray()).hex()
        val previous = prefs.getString("owner", null)
        if (previous != null && previous != identity)
            throw NotesException("This app's local notes belong to another Samsung account. Export them, then clear the app's storage before connecting a different account.")
        if (previous == null) prefs.edit().putString("owner", identity).commit()
    }

    fun setTwoWaySync(enabled: Boolean) {
        check(!enabled || isSignedIn()) { "Sign in before enabling cloud sync." }
        context.getSharedPreferences("CloudBridge", Context.MODE_PRIVATE).edit().putBoolean("twoWaySync", enabled).commit()
        if (!enabled) runCatching { nativeCompanion().let { it.javaClass.getMethod("setSyncEnableByUserClick", Boolean::class.javaPrimitiveType).invoke(it, false) } }
    }

    private fun nativeCompanion(): Any = requireNotNull(Class.forName("com.samsung.android.support.senl.nt.base.common.sync.RequestToSyncManager").getField("Companion").get(null))
    @JvmStatic fun isAccountProviderAvailable(): Boolean = this::context.isInitialized
    @JvmStatic fun requiredSyncPermissions(): java.util.ArrayList<String> = arrayListOf<String>().apply {
        // Browser OAuth and our UUID-based enrollment use no contacts, system
        // AccountManager account or telephony identifier. Keep OS permission
        // checks honest; only the actual network permission is required here.
        if (context.checkSelfPermission(android.Manifest.permission.INTERNET) != android.content.pm.PackageManager.PERMISSION_GRANTED)
            add(android.Manifest.permission.INTERNET)
    }
    @JvmStatic fun userId(): String = credentials?.userID.orEmpty()
    @JvmStatic fun userHash(): String = credentials?.userID?.let { sha256(it.toByteArray()).hex().uppercase(Locale.ROOT) }.orEmpty()
    @JvmStatic fun accountName(): String = credentials?.loginID.orEmpty()
    fun hasSavedCloudAuthorization(): Boolean = credentials?.cloudAuthorization?.startsWith("Bearer ") == true
    @JvmStatic fun accountServer(): String = credentials?.authServer.orEmpty()
    @JvmStatic fun accessToken(): String = credentials?.takeIf { !expired && it.accessExpires > System.currentTimeMillis() + 120_000 }?.accessToken.orEmpty()
    @JvmStatic fun invalidate() { expired = true }
    @JvmStatic fun openAccount(host: Activity, requestCode: Int) {
        host.startActivityForResult(Intent(host, AccountActivity::class.java), requestCode)
    }
    @JvmStatic fun accountIntent(host: Context): Intent = Intent(host, AccountActivity::class.java)

    private suspend fun renewed(): NativeCredentials = refresh.withLock {
        val current = credentials ?: throw NotesException("Sign in from Settings > Samsung Cloud.")
        SamsungSignIn.cloudSession(current, expired).also(SessionStore::save)
        NativeAuthStore.load().also { credentials = it; expired = false }
    }

    private fun callback(listener: Any, name: String, vararg values: String) {
        // Compile without bundling Samsung's interfaces or implementation.
        val method = listener.javaClass.getMethod(name, *Array(values.size) { String::class.java })
        method.isAccessible = true
        method.invoke(listener, *values)
    }

    @JvmStatic fun requestAuth(listener: Any) {
        scope.launch(Dispatchers.IO) {
            try {
                val value = withContext(Dispatchers.IO) { renewed() }
                callback(listener, "onReceived", value.accessToken, value.userID)
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { callback(listener, "onError", "CLOUD_BETA_SIGN_IN_REQUIRED", "Open Settings > Samsung Cloud to reconnect.") }
        }
    }

    @JvmStatic fun cloudAuthorization(): String {
        if (!NATIVE_READ_ENABLED || Looper.myLooper() == Looper.getMainLooper()) return ""
        return runBlocking(Dispatchers.IO) {
            runCatching { renewed().cloudAuthorization }.getOrDefault("")
        }
    }

    @JvmStatic fun requestCloudAuthorization(listener: Any) {
        // The original q3/b implementation delivers this from its dedicated
        // GetAuthorizationThread. Native callers can wait for it synchronously.
        scope.launch(Dispatchers.IO) {
            if (!NATIVE_READ_ENABLED) {
                callback(listener, "onError", "CLOUD_BETA_NOT_VALIDATED", "Native cloud sync is still under test.")
            } else {
                val token = withContext(Dispatchers.IO) { cloudAuthorization() }
                if (token.isEmpty()) callback(listener, "onError", "CLOUD_BETA_SIGN_IN_REQUIRED", "Open Settings > Samsung Cloud to reconnect.")
                else callback(listener, "onReceived", token)
            }
        }
    }

    @JvmStatic fun serverUrl(path: String): String {
        // The native app also reads account quota and time from this service.
        // URL construction and note-write authorization are separate boundaries.
        // The native sync preflight also asks for the bare service URL.
        require(path.isEmpty() || (path.startsWith("/") && !path.startsWith("//"))) { "Invalid native Samsung service path." }
        val target = "https://api.samsungcloud.com$path"
        val uri = java.net.URI(target)
        require(uri.host == "api.samsungcloud.com" && uri.rawUserInfo == null && uri.rawFragment == null) { "Invalid native Samsung service." }
        return target
    }

    @JvmStatic @Synchronized fun allowNativeRequest(address: String?, method: String?): Boolean {
        val allowed = !signingOut && isSignedIn() && (if (isNativeReadOnly())
            NativeReadPolicy.allows(address, method) || NativeUploadProbe.allows(address, method)
            else NativeSyncPolicy.allows(address, method))
        if (allowed) nativeReads++ else blockedWrites++
        // Only fixed protocol vocabulary is logged. Arbitrary path components,
        // account/note IDs, hosts, query strings and credentials are omitted.
        val protocolWords = setOf("samsungnotes", "v1", "v2", "v3", "notes", "folder", "changes", "list", "info", "prepareForDownsync", "compareForDownsync", "compareForUpsync", "update", "delete", "create", "binaries", "createUploadURLs")
        val route = runCatching { java.net.URI(address ?: "").path.split('/').joinToString("/") { if (it in protocolWords || it.isEmpty()) it else "{value}" } }.getOrDefault("invalid")
        android.util.Log.i("SCNotesCloudBeta", "Native request ${if (allowed) "allowed" else "blocked"}; method=$method; route=$route; reads=$nativeReads; blocked=$blockedWrites")
        return allowed
    }

    @JvmStatic fun runNativeUploadProbe(task: Any) { NativeUploadProbe.run(context, task) }
    @JvmStatic fun skipNativeUploads(task: Any): Boolean {
        if (!isNativeReadOnly()) return false
        runNativeUploadProbe(task)
        return true
    }

    @JvmStatic fun nativeSyncEnded(errorCode: Int) {
        syncCompletion?.complete(errorCode)
        context.getSharedPreferences("CloudBridge", Context.MODE_PRIVATE).edit()
            .putLong("lastSyncAt", System.currentTimeMillis()).putInt("lastSyncError", errorCode).commit()
        scope.launch { activity?.get()?.showSyncStatus() }
    }

    fun lastSyncStatus(): String {
        val prefs = context.getSharedPreferences("CloudBridge", Context.MODE_PRIVATE)
        val at = prefs.getLong("lastSyncAt", 0)
        if (at == 0L) return "Notes are stored on this device for offline use."
        val time = android.text.format.DateFormat.getMediumDateFormat(context).format(java.util.Date(at)) + " " +
            android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(at))
        return if (prefs.getInt("lastSyncError", 0) == 0) "Last synced $time. Notes are available offline."
            else "Last sync could not finish ($time). Local notes and pending edits are kept."
    }

    fun requestNativeSync(status: (String) -> Unit) {
        if (syncJob?.isActive == true) return
        syncJob = scope.launch {
            try {
                withContext(Dispatchers.IO) { renewed() }
                syncCompletion = CompletableDeferred()
                val companion = nativeCompanion()
                val type = requireNotNull(companion).javaClass
                type.getMethod("setSyncEnableByUserClick", Boolean::class.javaPrimitiveType).invoke(companion, true)
                type.getMethod("requestSyncBackground").invoke(companion)
                status(if (isNativeReadOnly()) "Downloading notesâ€¦" else "Syncing notesâ€¦")
                val result = withTimeoutOrNull(120_000) { syncCompletion?.await() }
                status(when (result) { 0 -> lastSyncStatus(); null -> "Sync is still running. You can return to your notes."; else -> "Sync could not finish (code $result). Local notes and pending edits are kept." })
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { status("Could not sync right now. Local notes and edits are kept. Check your connection or sign in again.") }
        }
    }

    fun attach(host: AccountActivity) { activity = WeakReference(host) }
    fun deliver(uri: Uri?) { if (uri?.scheme == "ms-app") browser?.complete(uri.toString()) }
    fun connect(status: (String) -> Unit, done: () -> Unit) {
        if (accountJob?.isActive == true) return
        accountJob = scope.launch {
            try {
                status("Opening Samsung sign-inâ€¦")
                val value = SamsungSignIn.signIn { message -> scope.launch { status(message) } }
                try { bindAccount(value) } catch (error: Exception) { SamsungSignIn.signOut(); throw error }
                credentials = value
                signingOut = false
                withContext(Dispatchers.IO) { renewed() }
                status("Connected to Samsung Cloud. Choose download-only or two-way sync below.")
            } catch (error: CancellationException) { status("Sign-in cancelled.") }
            catch (error: Exception) { status(error.message ?: "Samsung sign-in failed.") }
            finally { done() }
        }
    }
    fun checkConnection(status: (String) -> Unit, done: () -> Unit) {
        if (accountJob?.isActive == true) return
        accountJob = scope.launch {
            try {
                status("Checking the saved Samsung connectionâ€¦")
                withContext(Dispatchers.IO) {
                    val value = renewed()
                    val cursor = base64("{\"appVersion\":\"0\",\"encryptedGuid\":\"\",\"modifiedTime\":0,\"purpose\":\"INITIAL\",\"requestTimeStamp\":0,\"sdkVersion\":\"0\",\"type\":\"NOTE\",\"version\":0}".toByteArray())
                    val query = java.net.URLEncoder.encode(cursor, "UTF-8")
                    val (code, bytes) = Http.send("https://api.samsungcloud.com/samsungnotes/v1/notes/changes?lastChangePoint=$query", "GET", mapOf(
                        "Authorization" to value.cloudAuthorization, "x-sn-sdk-ver" to "5500", "x-sn-app-ver" to "4000",
                        "X-SN-XML-VER" to "2", "X-SN-Feature-ID" to "O4vARCbQ3G", "User-Agent" to ClientPlatform.userAgent,
                        "x-sn-model-name" to base64(ClientPlatform.model.toByteArray())), null, followRedirects = false)
                    if (code != 200) throw NotesException("Saved connection cloud check returned HTTP $code.")
                    val parser = Xml.newPullParser().apply { setInput(ByteArrayInputStream(bytes), "UTF-8") }
                    if (parser.nextTag() != org.xmlpull.v1.XmlPullParser.START_TAG || parser.name != "NoteChangesView")
                        throw NotesException("Samsung returned an unexpected cloud index.")
                }
                status("Connected to Samsung Cloud. ${lastSyncStatus()}")
            } catch (error: CancellationException) { status("Connection check cancelled.") }
            catch (error: Exception) { status(error.message ?: "Connection check failed.") }
            finally { done() }
        }
    }
    fun signOut(done: () -> Unit) {
        signingOut = true
        setTwoWaySync(false)
        browser?.cancel(); browser = null
        scope.launch {
            syncJob?.cancelAndJoin()
            accountJob?.cancelAndJoin()
            refresh.withLock { credentials = null; SamsungSignIn.signOut() }
            done()
        }
    }
}

class BridgeProvider : ContentProvider() {
    override fun onCreate(): Boolean { NotesBridge.init(requireNotNull(context)); return true }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, order: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?): Int = 0
}

class AccountActivity : Activity() {
    private lateinit var account: TextView
    private lateinit var status: TextView
    private lateinit var connect: Button
    private lateinit var sync: Button
    private lateinit var twoWay: android.widget.Switch
    private var rendering = false

    fun showSyncStatus() { if (this::status.isInitialized) status.text = NotesBridge.lastSyncStatus() }

    private fun render() {
        rendering = true
        val signedIn = NotesBridge.isSignedIn()
        account.text = NotesBridge.accountName().ifEmpty { "No Samsung account connected" }
        account.isClickable = signedIn
        connect.visibility = if (signedIn) android.view.View.GONE else android.view.View.VISIBLE
        twoWay.visibility = if (signedIn) android.view.View.VISIBLE else android.view.View.GONE
        twoWay.isChecked = !NotesBridge.isNativeReadOnly()
        sync.visibility = if (signedIn) android.view.View.VISIBLE else android.view.View.GONE
        sync.text = if (NotesBridge.isNativeReadOnly()) "Download notes" else "Sync now"
        rendering = false
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        NotesBridge.attach(this); NotesBridge.deliver(intent?.data)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val inset = (24 * resources.displayMetrics.density).toInt()
            setPadding(inset, inset + 48, inset, inset)
        }
        val title = TextView(this).apply { text = "Samsung Cloud"; textSize = 26f }
        account = TextView(this).apply {
            textSize = 18f
            setPadding(0, 24, 0, 24)
            setOnClickListener {
                if (NotesBridge.isSignedIn()) android.widget.PopupMenu(this@AccountActivity, this).apply {
                    menu.add("Sign out").setOnMenuItemClickListener {
                        sync.isEnabled = false; twoWay.isEnabled = false
                        NotesBridge.signOut {
                            render(); sync.isEnabled = true; twoWay.isEnabled = true
                            status.text = "Signed out. Samsung Cloud is disconnected."
                        }
                        true
                    }
                    show()
                }
            }
        }
        status = TextView(this).apply { text = NotesBridge.lastSyncStatus() }
        connect = Button(this).apply {
            text = "Sign in with Samsung"
            setOnClickListener {
                isEnabled = false
                NotesBridge.connect({ message -> runOnUiThread { status.text = message } }) {
                    runOnUiThread { isEnabled = true; render() }
                }
            }
        }
        sync = Button(this).apply {
            setOnClickListener { NotesBridge.requestNativeSync { message -> if (!isFinishing && !isDestroyed) status.text = message } }
        }
        twoWay = android.widget.Switch(this).apply {
            text = "Two-way sync"
            setPadding(0, 24, 0, 24)
            setOnCheckedChangeListener { _, checked ->
                if (!rendering) {
                    NotesBridge.setTwoWaySync(checked)
                    status.text = if (checked) "Changes sync both ways. Offline edits are kept until you reconnect."
                        else "Download-only mode. Local edits are kept on this device."
                    render()
                    if (checked) NotesBridge.requestNativeSync { message -> if (!isFinishing && !isDestroyed) status.text = message }
                }
            }
        }
        layout.addView(title); layout.addView(account); layout.addView(status)
        layout.addView(connect); layout.addView(twoWay); layout.addView(sync)
        layout.addView(Button(this).apply {
            text = "Import Samsung Notes file"
            setOnClickListener { startActivity(Intent(this@AccountActivity, ImportNoteActivity::class.java)) }
        })
        layout.addView(TextView(this).apply { text = "${NotesBridge.version} \u00b7 Native Android beta"; setPadding(0, 24, 0, 24) })
        layout.addView(Button(this).apply {
            text = "Return to Samsung Notes"
            setOnClickListener {
                setResult(if (NotesBridge.isSignedIn()) RESULT_OK else RESULT_CANCELED)
                startActivity(Intent().setClassName(packageName, "com.samsung.android.app.notes.memolist.MemoListActivity"))
                finish()
            }
        })
        setContentView(layout)
        render()
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); NotesBridge.deliver(intent.data) }
    override fun onResume() { super.onResume(); render(); showSyncStatus() }
}
