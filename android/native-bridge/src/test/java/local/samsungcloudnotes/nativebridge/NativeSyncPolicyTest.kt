package local.samsungcloudnotes.nativebridge

import org.junit.Assert.*
import org.junit.Test

class NativeSyncPolicyTest {
    @Test fun permitsNativeSerializerAndBinaryTransfers() {
        assertTrue(NativeSyncPolicy.allows("https://api.samsungcloud.com/samsungnotes/v3/folder", "PATCH"))
        assertTrue(NativeSyncPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes", "POST"))
        assertTrue(NativeSyncPolicy.allows("https://api.samsungcloud.com/samsungnotes/v3/notes/test/update", "POST"))
        assertTrue(NativeSyncPolicy.allows("https://example.s3.amazonaws.com/binary?signature=example", "PUT"))
    }
    @Test fun rejectsOtherServicesAndAmbiguousDestinations() {
        for (url in listOf("http://api.samsungcloud.com/samsungnotes/v1/notes", "https://api.samsungcloud.com.evil.test/samsungnotes/v1/notes",
            "https://api.samsungcloud.com/identity/v1/tokens", "https://user@api.samsungcloud.com/samsungnotes/v1/notes",
            "https://api.samsungcloud.com:444/samsungnotes/v1/notes", "https://api.samsungcloud.com/samsungnotes/v3/notes/%2e%2e/delete",
            "https://api.samsungcloud.com/samsungnotes/v3/telemetry/sync-result", "https://example.test/binary"))
            assertFalse(url, NativeSyncPolicy.allows(url, "POST"))
        assertFalse(NativeSyncPolicy.allows("https://example.s3.amazonaws.com/binary", "DELETE"))
    }
}
