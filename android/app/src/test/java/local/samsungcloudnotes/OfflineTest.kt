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
    private val fixtureXml = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\" unknownField=\"retain\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><spanOrderDataList><spanOrderData val=\"stale\"/></spanOrderDataList><zeroLengthSpanList><zeroLengthSpan val=\"stale-zero\"/></zeroLengthSpanList><text>${StyledText.encode("Before")}</text></object></bodyText><pageList><page id=\"page\"><opaqueDrawing value=\"preserve\"/></page></pageList><contentFileList><contentFile id=\"asset\" hash=\"original\"/></contentFileList></noteResource><commitId>fixture-revision</commitId><downloadUrls/></CompareNoteView>"

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
        for (value in listOf("", "hello", "café — 日本語 🚀", "first\nsecond\n", "<&> \"quotes\"")) {
            assertEquals(value, StyledText.decode(StyledText.encode(value)))
            assertEquals(value.replace("\r\n", "\n"), StyledText.decode(StyledText.encodeTitle(value)))
        }
        assertEquals("", StyledText.encode(""))
        assertEquals("", StyledText.encodeTitle(""))
        val multi = String(base64Decode(StyledText.encode("first\nsecond"))!!)
        assertTrue(multi.contains("'span/fontSize'='1,15.0'"))
        assertTrue(multi.contains("'span/foregroundColor'='1,-14342875'"))
        assertEquals(2, multi.split("'paragraph/alignment'='0'").size - 1)
        assertEquals(2, multi.split("'paragraph/alignment' ").size - 1)
        assertEquals(2, multi.split("'paragraph/parsingState'='false'").size - 1)
        assertEquals(2, multi.split("'paragraph/parsingState' ").size - 1)
        val titleEncoded = String(base64Decode(StyledText.encodeTitle("Title"))!!)
        assertTrue(titleEncoded.contains("'paragraph/parsingState'='false'"))
        assertTrue(!titleEncoded.contains("span/fontSize"))
        assertTrue(!titleEncoded.contains("sectionData/sectionData"))
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
        val newBody = "After 日本語 🚀"
        val updated = XmlDocument(fixture.uploadXml("Test title", newBody))
        val resource = updated.rootElement()!!
        val updatedBodyObj = resource.first("bodyText")!!.first("object")!!
        val updatedOrders = updatedBodyObj.first("spanOrderDataList")!!.elements("spanOrderData").map {
            String(base64Decode(it.attr("val"))!!)
        }
        val updatedZeros = updatedBodyObj.first("zeroLengthSpanList")!!.elements("zeroLengthSpan")
        assertEquals("retain", resource.attr("unknownField"))
        assertEquals("0", resource.first("attributes")!!.attr("editTime"))
        assertEquals("0", updatedBodyObj.attr("timeStamp"))
        assertEquals(listOf("3,0,${newBody.length},1,15.0", "1,0,${newBody.length},1,-14342875"), updatedOrders)
        assertTrue(updatedZeros.isEmpty())
        assertEquals("preserve", resource.first("pageList")!!.first("page")!!.first("opaqueDrawing")!!.attr("value"))
        assertEquals("original", resource.first("contentFileList")!!.first("contentFile")!!.attr("hash"))
        assertEquals(newBody, StyledText.decode(updatedBodyObj.value("text")))
        assertEquals(StyledText.encodeTitle("Test title"), resource.first("attributes")!!.first("title")!!.first("object")!!.value("text"))
        assertEquals("Test title", StyledText.decode(resource.first("attributes")!!.first("title")!!.first("object")!!.value("text")))
        assertEquals(updatedBodyObj.attr("hash"), resource.first("noteTree")!!.first("bodyText")!!.attr("h"))

        val legacyPayload = base64(("<?a 'paragraph/alignment'='0' 'paragraph/parsingState'='False' 'span/fontSize'='1,12' 'span/foregroundColor'='1,-14342875' 'sectionData/sectionData'='6'?>" + base64("Legacy".toByteArray()) + "<?a 'span/foregroundColor' 'span/fontSize' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>").toByteArray())
        val legacyXml = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes editTime=\"1794667044333760\"><title><object><text>$legacyPayload</text></object></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\" timeStamp=\"1794667044333760\"><spanOrderDataList><spanOrderData val=\"stale\"/></spanOrderDataList><text>$legacyPayload</text></object></bodyText></noteResource><commitId>legacy-rev</commitId></CompareNoteView>"
        val legacyDoc = CloudDocument("legacy", legacyXml.toByteArray())
        assertTrue(legacyDoc.needsNativeRepair)
        val fixedResource = String(legacyDoc.uploadXml(legacyDoc.title, legacyDoc.body))
        val fixedDoc = CloudDocument("legacy", "<CompareNoteView>$fixedResource<commitId>fixed-rev</commitId></CompareNoteView>".toByteArray())
        assertTrue(!fixedDoc.needsNativeRepair)
        assertEquals("Legacy", fixedDoc.body)
        assertEquals("Legacy", fixedDoc.title)
        assertEquals("0", fixedDoc.bodyObject!!.attr("timeStamp"))
        assertEquals("0", fixedDoc.resource.first("attributes")!!.attr("editTime"))

        val syncFixture = CloudDocument("sync-fixture", fixtureXml.toByteArray())
        syncFixture.resource.set("syncModifiedTime", "1800000000000")
        val saved = XmlDocument(syncFixture.uploadXml("Phone sync", "New body", nowMillis = 1_700_000_000_000L)).rootElement()!!
        assertEquals("1800000000001", saved.attr("syncModifiedTime"))
        assertEquals("1800000000001", saved.first("attributes")!!.attr("displayModifiedTime"))
        assertEquals("1800000000001000", saved.first("attributes")!!.attr("modifiedTime"))
        assertEquals("1800000000001000", saved.first("bodyText")!!.first("object")!!.attr("modifiedTime"))
        assertEquals("1800000000001000", saved.first("noteTree")!!.first("bodyText")!!.attr("t"))
        val repeated = XmlDocument(syncFixture.uploadXml("Phone sync", "New body", nowMillis = 1_700_000_000_000L)).rootElement()!!
        assertEquals("1800000000002", repeated.attr("syncModifiedTime"))

        val deltaFixture = CloudDocument("delta-fixture", fixtureXml.toByteArray())
        val delta = XmlDocument(deltaFixture.uploadTextDelta("Changed", "New text")).rootElement()!!
        assertNull(delta.first("pageList"))
        assertNull(delta.first("contentFileList"))
        assertNotNull(delta.first("noteTree"))
        assertEquals("New text", StyledText.decode(delta.first("bodyText")!!.first("object")!!.value("text")))
        assertEquals("preserve", deltaFixture.resource.first("pageList")!!.first("page")!!.first("opaqueDrawing")!!.attr("value"))
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
