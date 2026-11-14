package local.samsungcloudnotes.nativebridge

/** Rebuilds disposable page images from the native vector objects on open. */
object NativeCanvas {
    @JvmStatic fun prepare(note: Any) {
        runCatching {
            val type = Class.forName("com.samsung.android.sdk.pen.worddoc.SpenWNote")
            val wasChanged = type.getMethod("isChanged").invoke(note) as Boolean
            val pages = type.getMethod("getPageList").invoke(note) as List<*>
            val strokeType = Class.forName("com.samsung.android.sdk.pen.document.SpenObjectStroke")
            var cleared = false
            for (page in pages.filterNotNull()) {
                val objects = page.javaClass.getMethod("getObjectList").invoke(page) as List<*>
                // A cache-only/opaque page keeps its original representation.
                if (objects.any { it != null && strokeType.isInstance(it) }) {
                    page.javaClass.getMethod("clearCanvasCacheData").invoke(page)
                    cleared = true
                }
            }
            // Cache invalidation must not turn opening an unchanged note into
            // a cloud edit. Preserve changes already recovered by the loader.
            if (cleared && !wasChanged && type.getMethod("isChanged").invoke(note) == true)
                type.getMethod("clearChangedFlag").invoke(note)
        }.onFailure { android.util.Log.w("SCNotesCloudBeta", "Native canvas preparation unavailable: ${it.javaClass.simpleName}") }
    }
}
