package local.samsungcloudnotes.nativebridge

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.TextView
import kotlinx.coroutines.*

/** Handles document providers whose opaque URIs have no filename extension. */
class ImportNoteActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var status: TextView

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        status = TextView(this).apply { text = "Choose a Samsung Notes .sdocx file."; setPadding(32, 96, 32, 32) }
        setContentView(status)
        if (state == null) startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/sdoc", "application/octet-stream", "application/zip"))
        }, 1)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 1) return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { finish(); return }
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) it.getString(0) else null
                    }.orEmpty()
                    require(name.endsWith(".sdocx", ignoreCase = true))
                    contentResolver.openInputStream(uri)?.use {
                        val header = ByteArray(4)
                        java.io.DataInputStream(it).readFully(header)
                        require(header.contentEquals(byteArrayOf(0x50, 0x4b, 0x03, 0x04)))
                    } ?: error("No file data")
                }
                startActivity(Intent(Intent.ACTION_VIEW).apply {
                    setClassName(packageName, "com.samsung.android.support.senl.nt.app.trigger.DocOpenTriggerActivity")
                    setDataAndType(uri, "application/sdoc")
                    clipData = ClipData.newRawUri("Samsung Notes file", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                })
                finish()
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { status.text = "This is not a readable Samsung Notes .sdocx file. Go back to choose another file." }
        }
    }
    override fun onDestroy() { scope.cancel(); super.onDestroy() }
}
