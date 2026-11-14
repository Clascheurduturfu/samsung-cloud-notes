package local.samsungcloudnotes.nativebridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.TextView
import kotlinx.coroutines.*

/** Standard Android file export for the native editor's Samsung Notes share. */
class SaveExportActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var status: TextView
    private var source: Uri? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { text = "Choose where to save the Samsung Notes file."; setPadding(32, 96, 32, 32) }
        setContentView(status)
        source = if (savedInstanceState != null) savedInstanceState.getParcelable("source")
            else if (intent.action == Intent.ACTION_SEND) intent.getParcelableExtra(Intent.EXTRA_STREAM) else null
        if (source?.scheme != "content") { status.text = "No Samsung Notes file was shared."; return }
        if (savedInstanceState == null) {
            val name = runCatching {
                contentResolver.query(requireNotNull(source), arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                }
            }.getOrNull()?.substringAfterLast('/')?.substringAfterLast('\\')?.takeIf { it.isNotBlank() } ?: "Samsung note.sdocx"
            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/sdoc"
                putExtra(Intent.EXTRA_TITLE, name)
            }, 1)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putParcelable("source", source)
        super.onSaveInstanceState(outState)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 1) return
        if (resultCode != RESULT_OK || data?.data == null) { finish(); return }
        val destination = requireNotNull(data.data)
        scope.launch {
            try {
                status.text = "Saving Samsung Notes file…"
                withContext(Dispatchers.IO) {
                    requireNotNull(contentResolver.openInputStream(requireNotNull(source))).use { input ->
                        requireNotNull(contentResolver.openOutputStream(destination, "wt")).use { output -> input.copyTo(output) }
                    }
                }
                status.text = "Samsung Notes file saved."
                setResult(RESULT_OK)
                finish()
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { status.text = "Could not save the file. Share it again to retry." }
        }
    }

    override fun onDestroy() { scope.cancel(); super.onDestroy() }
}
