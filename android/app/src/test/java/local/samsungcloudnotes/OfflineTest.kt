package local.samsungcloudnotes

import java.io.File
import java.nio.file.Files
import java.security.KeyPairGenerator
import javax.crypto.Cipher
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors Sources/Shared/SelfTest.swift: no network, Keystore or account access. */
class OfflineTest {
    private val fixtureXml = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\" unknownField=\"retain\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><text>${StyledText.encode("Before")}</text></object></bodyText><pageList><page id=\"page\"><opaqueDrawing value=\"preserve\"/></page></pageList><contentFileList><contentFile id=\"asset\" hash=\"original\"/></contentFileList></noteResource><commitId>fixture-revision</commitId><downloadUrls/></CompareNoteView>"

    @Test fun pkceReferenceVector() {
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", SamsungAuthCrypto.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }

    @Test fun callbackDecryption() {
        val encrypted = SamsungAuthCrypto.aes("synthetic-callback".toByteArray(), "0123456789abcdef".toByteArray(), encrypt = true, ecb = true).hex()
        assertEquals("synthetic-callback", SamsungAuthCrypto.callback(encrypted, "0123456789abcdef-extra"))
        assertThrows(NotesException::class.java) { SamsungAuthCrypto.callback("not-hex", "test") }
    }

    @Test fun envelopeDecryptsWithTheServerKey() {
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.genKeyPair()
        val sealed = JSONObject(String(base64Decode(SamsungAuthCrypto.envelope(JSONObject().put("state", "x"), 7, base64(pair.public.encoded)))!!))
        assertEquals("7", sealed.getString("chkDoNum"))
        val key = base64Decode(String(Cipher.getInstance("RSA/ECB/PKCS1Padding").apply { init(Cipher.DECRYPT_MODE, pair.private) }
            .doFinal(base64Decode(sealed.getString("svcEncKY")))))!!
        assertEquals(16, key.size)
        val iv = sealed.getString("svcEncIV").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val payload = SamsungAuthCrypto.aes(base64Decode(sealed.getString("svcEncParam"))!!, key, iv, encrypt = false)
        assertEquals("x", JSONObject(String(payload)).getString("state"))
    }

    @Test fun styledTextRoundTrip() {
        for (value in listOf("", "hello", "café — 日本語 🚀", "first\nsecond\n", "<&> \"quotes\"")) assertEquals(value, StyledText.decode(StyledText.encode(value)))
        val mixed = "<?a 'span/bold'='1,True'?>" + base64("one".toByteArray()) + "<?a 'span/bold'?>" + base64("\ntwo".toByteArray())
        assertEquals("one\ntwo", StyledText.decode(base64(mixed.toByteArray())))
    }

    @Test fun folderNames() {
        assertEquals("Math notes", decodedCloudName(base64("Math notes​".toByteArray())))
        assertEquals("Math notes 📒", decodedCloudName(base64("Math notes 📒".toByteArray())))
        assertEquals("My notes", decodedCloudName("My notes"))
    }

    @Test fun inkStroke() {
        val fixture = base64Decode("/////wQAAACgDwAADQAAAAAADQAAAAEIAEoAAAABAEIAAAABAAEMAgAAAAAAAAAkQAAAAAAAADRAAAAAAAAAPkAAAAAAAABEQAAAAD8AAEA/AAAAAAoAAAACAFY0Ev8AAEBA")!!
        val ink = InkStroke(fixture)
        assertEquals(2, ink.points.size)
        assertEquals(InkPoint(30.0, 40.0), ink.points[1])
        assertEquals(0xff123456L, ink.color)
        assertThrows(NotesException::class.java) { InkStroke(fixture.copyOf(25)) }
    }

    @Test fun initialCursor() {
        assertEquals("INITIAL", JSONObject(String(base64Decode(CloudClient.initialCursor("NOTE"))!!)).getString("purpose"))
    }

    @Test fun xmlRoundTripAndEscaping() {
        val document = XmlDocument(fixtureXml.toByteArray())
        assertEquals(document.xmlString(), XmlDocument(document.xmlString().toByteArray()).xmlString())
        val escaped = XmlDocument("<?xml version=\"1.0\"?><!-- c --><a x='1 &amp; &quot;2&quot;' y=\"&#x1F680;\"><b/>t&lt;&#233;<![CDATA[<raw>]]></a>".toByteArray())
        assertEquals("1 & \"2\"", escaped.rootElement()!!.attr("x"))
        assertEquals("🚀", escaped.rootElement()!!.attr("y"))
        assertEquals("t<é<raw>", escaped.rootElement()!!.stringValue)
        assertEquals("<?xml version=\"1.0\"?><!-- c --><a x=\"1 &amp; &quot;2&quot;\" y=\"🚀\"><b/>t&lt;é<![CDATA[<raw>]]></a>", escaped.xmlString())
        for (invalid in listOf("<a><b></a>", "<!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>", "<a/><b/>", "<a x='1' x='2'/>")) {
            assertThrows(NotesException::class.java) { XmlDocument(invalid.toByteArray()) }
        }
    }

    @Test fun uploadPreservesUnknownContent() {
        val fixture = CloudDocument("fixture", fixtureXml.toByteArray())
        assertEquals("Before", fixture.body)
        val updated = XmlDocument(fixture.uploadXml("Test title", "After 日本語 🚀"))
        val resource = updated.rootElement()!!
        assertEquals("retain", resource.attr("unknownField"))
        assertEquals("preserve", resource.first("pageList")!!.first("page")!!.first("opaqueDrawing")!!.attr("value"))
        assertEquals("original", resource.first("contentFileList")!!.first("contentFile")!!.attr("hash"))
        assertEquals("After 日本語 🚀", StyledText.decode(resource.first("bodyText")!!.first("object")!!.value("text")))
        assertEquals("Test title", StyledText.decode(resource.first("attributes")!!.first("title")!!.first("object")!!.value("text")))
        assertEquals(resource.first("bodyText")!!.first("object")!!.attr("hash"), resource.first("noteTree")!!.first("bodyText")!!.attr("h"))
    }

    @Test fun cacheIsRevisionAndSessionScoped() {
        val base = Files.createTempDirectory("scn-cache").toFile()
        try {
            val session = AccountSession("Bearer synthetic-connection-fixture", "Fixture")
            val fixture = CloudDocument("fixture", fixtureXml.toByteArray())
            val cache = NoteCache(session, base)
            var record = NoteRecord("fixture", "r", "revision-1", 0.0, locked = false, encrypted = false)
            cache.save(fixture, record.commit)
            cache.saveIndex(CloudIndex(listOf(record), emptyList()))
            val reopened = NoteCache(session, base)
            assertEquals(1, reopened.snapshot()!!.index.notes.size)
            assertEquals("Before", reopened.document(record)!!.body)
            assertNull(reopened.document(record.copy(commit = "revision-2")))
            assertNull(reopened.document(record.copy(locked = true)))
            val nativeOne = NoteCache(AccountSession("Bearer synthetic-native-first", "Fixture", "native:fixture:mac"), base)
            nativeOne.saveIndex(CloudIndex(listOf(record), emptyList()))
            assertNotNull(NoteCache(AccountSession("Bearer synthetic-native-renewed", "Fixture", "native:fixture:mac"), base).snapshot())
            assertNull(NoteCache(AccountSession("Bearer synthetic-other-account", "Fixture", "native:other:mac"), base).snapshot())
            assertNull(NoteCache(AccountSession("Bearer different-synthetic-session", "Fixture"), base).snapshot())
            cache.saveAsset("offline attachment".toByteArray(), "asset", "one")
            assertEquals("offline attachment", String(reopened.asset("asset", "one")!!))
            assertNull(reopened.asset("asset", "two"))
            reopened.prune(emptyList())
            assertNull(reopened.document(record))
            assertTrue(File(reopened.root, "index.json").exists())
        } finally { base.deleteRecursively() }
    }
}
