package local.samsungcloudnotes

import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.content.FileProvider
import java.io.File
import java.lang.ref.WeakReference
import kotlinx.coroutines.CompletableDeferred

class NotesApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        LocalStore.init(this)
        SamsungSignIn.browser = { url -> SignInBridge.open(url) }
    }
}

/**
 * Hands Samsung's sign-in page to the user's browser (Custom Tab) and waits for
 * the ms-app:// callback, which Android routes back to [MainActivity].
 * Lives outside the activity so a rotation during sign-in does not lose it.
 */
object SignInBridge {
    private var pending: CompletableDeferred<String>? = null
    private var launched = false
    var activity: WeakReference<MainActivity>? = null

    suspend fun open(url: String): String {
        val host = activity?.get() ?: throw NotesException("This device could not open Samsung sign-in.")
        pending?.cancel()
        val deferred = CompletableDeferred<String>()
        pending = deferred
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(host, Uri.parse(url))
        } catch (_: ActivityNotFoundException) {
            pending = null
            throw NotesException("Install or enable a web browser to sign in with Samsung.")
        }
        launched = true
        return deferred.await()
    }
    fun deliver(callback: Uri): Boolean {
        if (callback.scheme != "ms-app") return false
        launched = false
        val deferred = pending
        pending = null
        if (deferred == null) return true // A stale callback, e.g. after the app was restarted.
        deferred.complete(callback.toString())
        return true
    }
    /** Returning from the browser without a callback means the user closed it. */
    fun resumed() {
        if (!launched) return
        launched = false
        pending?.completeExceptionally(NotesException("Samsung sign-in was cancelled."))
        pending = null
    }
}

class MainActivity : ComponentActivity() {
    private val model: NotesViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        SignInBridge.activity = WeakReference(this)
        intent?.data?.let { SignInBridge.deliver(it) }
        setContent { NotesTheme { NotesApp(model, ::openFile) } }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { SignInBridge.deliver(it) }
    }
    override fun onResume() {
        super.onResume()
        SignInBridge.activity = WeakReference(this)
        SignInBridge.resumed()
    }
    override fun onStop() {
        super.onStop()
        model.preserveDraft()
    }

    private fun openFile(file: File, mime: String) {
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try { startActivity(Intent.createChooser(view, file.name)) }
        catch (_: ActivityNotFoundException) { model.error = "No installed app can open this file type." }
    }
}
