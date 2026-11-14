package local.samsungcloudnotes.nativebridge

import org.junit.Assert.*
import org.junit.Test

class NativeUploadProbeTest {
    @Test fun normalBuildCannotWrite() {
        assertEquals("", BuildConfig.UPLOAD_PROBE_UUID)
        assertFalse(NativeUploadProbe.allows("https://api.samsungcloud.com/samsungnotes/v3/notes", "POST"))
    }

    @Test fun evenAnActiveProbeCannotMutateExistingNotesOrFolders() {
        for (verb in listOf("GET", "POST", "PATCH", "PUT", "DELETE")) {
            for (path in listOf("notes/existing/update", "notes/existing/delete", "folder", "notes/existing/compareForUpsync", "telemetry/sync-result"))
                assertFalse(NativeUploadProbe.permitsCreateTransfer("https://api.samsungcloud.com/samsungnotes/v3/$path", verb))
        }
        assertFalse(NativeUploadProbe.permitsCreateTransfer("https://api.samsungcloud.com.evil.test/samsungnotes/v3/notes", "POST"))
        assertFalse(NativeUploadProbe.permitsCreateTransfer("http://example.s3.amazonaws.com/object", "PUT"))
    }

    @Test fun probeAllowsOnlyCreationAndBinaryTransferShapes() {
        assertTrue(NativeUploadProbe.permitsCreateTransfer("https://api.samsungcloud.com/samsungnotes/v3/notes", "POST"))
        assertTrue(NativeUploadProbe.permitsCreateTransfer("https://api.samsungcloud.com/samsungnotes/v3/binaries/createUploadURLs", "POST"))
        assertTrue(NativeUploadProbe.permitsCreateTransfer("https://example.s3.amazonaws.com/object", "PUT"))
    }
}
