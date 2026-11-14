package local.samsungcloudnotes.nativebridge

import org.junit.Assert.*
import org.junit.Test

class NativeReadPolicyTest {
    @Test fun permitsNativeReadAndDownloadPreparation() {
        assertTrue(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/changes?lastChangePoint=abc", "GET"))
        assertTrue(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v3/folder/changes", "GET"))
        assertTrue(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/test-note/prepareForDownsync", "POST"))
        assertTrue(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/test-note/compareForDownsync", "POST"))
        assertTrue(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v3/notes/list", "POST"))
        assertFalse(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/test-note/compareForUpsync", "POST"))
        assertTrue(NativeReadPolicy.allows("https://example.s3.amazonaws.com/note-page?signature=example", "GET"))
    }
    @Test fun rejectsEveryMutationVerbAndWriteEndpoint() {
        for (verb in listOf("PUT", "PATCH", "DELETE", "POST")) {
            assertFalse(verb, NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/test-note/update", verb))
            assertFalse(verb, NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/folder/changes", verb))
        }
        assertFalse(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/test-note/delete", "GET"))
        assertFalse(NativeReadPolicy.allows("https://example.s3.amazonaws.com/note-page", "PUT"))
    }
    @Test fun rejectsAmbiguousOrUntrustedDestinations() {
        for (address in listOf("http://api.samsungcloud.com/samsungnotes/v1/notes/changes", "https://api.samsungcloud.com.evil.test/samsungnotes/v1/notes/changes",
            "https://user@api.samsungcloud.com/samsungnotes/v1/notes/changes", "https://api.samsungcloud.com:444/samsungnotes/v1/notes/changes",
            "https://api.samsungcloud.com/samsungnotes/v1/notes/../delete", "https://api.samsungcloud.com/samsungnotes/v1/notes/%2e%2e/changes",
            "https://api.samsungcloud.com/identity/v1/tokens", "https://api.samsungcloud.com/samsungnotes/v1/notes/changes#fragment"))
            assertFalse(address, NativeReadPolicy.allows(address, "GET"))
        assertFalse(NativeReadPolicy.allows(null, "GET"))
        assertFalse(NativeReadPolicy.allows("https://api.samsungcloud.com/samsungnotes/v1/notes/changes", null))
    }
}
