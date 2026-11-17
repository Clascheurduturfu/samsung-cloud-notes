package local.samsungcloudnotes

import java.io.File
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the rich-text checks in Sources/Shared/SelfTest.swift. */
class RichTextTest {
    /** Builds a Samsung-style payload: `parts` alternate between marker bodies and plain text. */
    private fun payload(vararg parts: String): String {
        val out = StringBuilder()
        parts.forEachIndexed { i, part -> if (i % 2 == 0) { if (part.isNotEmpty()) out.append("<?a ").append(part).append("?>") } else out.append(base64(part.toByteArray())) }
        return base64(out.toString().toByteArray())
    }
    private fun record(value: String) = base64(value.toByteArray())

    // "Title line\nCheck\nBold word\nEnd" with Samsung-like structure: per-paragraph
    // parsingState (leading newline convention), a checkbox paragraph, a bold span,
    // a red span and whole-text defaults.
    private val text = "Title line\nCheck\nBold word\nEnd"
    private val encoded = payload(
        "'paragraph/alignment'='0' 'paragraph/alignment' 'span/fontSize'='1,15.0' 'span/foregroundColor'='1,-14342875' 'paragraph/parsingState'='false' 'sectionData/sectionData'='30'", "Title line",
        "'paragraph/parsingState' 'paragraph/parsingState'='false' 'paragraph/bullet'='checker,0'", "\nCheck",
        "'paragraph/parsingState' 'paragraph/bullet' 'paragraph/parsingState'='false'", "\n",
        "'span/bold'='1,True'", "Bold",
        "'span/bold' 'span/foregroundColor' 'span/foregroundColor'='-65536'", " word",
        "'span/foregroundColor' 'span/foregroundColor'='1,-14342875' 'paragraph/parsingState' 'paragraph/parsingState'='false'", "\nEnd",
        "'span/fontSize' 'span/foregroundColor' 'paragraph/parsingState' 'sectionData/sectionData'", "",
        "'sectionData/sectionData'='0' 'sectionData/sectionData'", "",
    )
    private val order = listOf(
        record("3,0,30,1,15.0"), record("1,0,21,1,-14342875"), record("5,17,21,1,True"),
        record("1,21,26,-65536"), record("1,26,30,1,-14342875"),
    )

    private fun rich() = RichText.parse(encoded, order)
    private fun find(r: RichText, key: String) = r.ranges.filter { it.key == key && it.end > it.start }.map { it.start to it.end }
    private fun simple(r: RichText) = r.ranges.map { listOf(it.key, it.value, it.start, it.end) }.sortedBy { it.toString() }

    @Test fun parsesSamsungMarkup() {
        val r = rich()
        assertEquals(text, r.text)
        assertEquals(text, StyledText.decode(encoded))
        assertEquals(listOf(17 to 21), find(r, "span/bold"))
        assertEquals(listOf(10 to 16), find(r, "paragraph/bullet"))
        assertEquals(listOf(0 to 10, 10 to 16, 16 to 26, 26 to 30), find(r, "paragraph/parsingState"))
        assertEquals(5, r.ranges.count { it.typeId != null })
    }

    @Test fun reencodingIsLossless() {
        val r = rich()
        val again = RichText.parse(r.encode(), r.spanOrderData())
        assertEquals(simple(r), simple(again))
        assertEquals(order, r.spanOrderData())
        assertSame(r, r.withText(text))
    }

    @Test fun typingInsideAndAtTheEndOfASpanExtendsIt() {
        val r = rich().withText("Title line\nCheck\nBoold word!\nEnd")
        assertEquals(listOf(17 to 22), find(r, "span/bold"))
        assertEquals("32", r.ranges.first { it.key == "sectionData/sectionData" && it.end > it.start }.value)
        val appended = rich().withText(text + " more")
        assertEquals(listOf(26 to 35), find(appended, "paragraph/parsingState").takeLast(1))
        assertEquals(listOf(0 to 35), find(appended, "span/fontSize"))
    }

    @Test fun typingBeforeASpanShiftsIt() {
        val r = rich().withText("Title line\nCheck\nVery Bold word\nEnd")
        assertEquals(listOf(22 to 26), find(r, "span/bold"))
        val first = rich().withText("New " + text)
        assertEquals(listOf(0 to 34), find(first, "span/fontSize"))
        assertEquals(listOf(21 to 25), find(first, "span/bold"))
    }

    @Test fun deletingAStyledWordRemovesOnlyItsStyle() {
        val r = rich().withText("Title line\nCheck\n word\nEnd")
        assertTrue(find(r, "span/bold").isEmpty())
        assertEquals(listOf(10 to 16), find(r, "paragraph/bullet"))
        val data = r.normalizedForUpload().spanOrderData().map { String(base64Decode(it)!!) }
        assertEquals(listOf("3,0,26,1,15.0", "1,0,17,1,-14342875", "1,17,22,-65536", "1,22,26,1,-14342875"), data)
    }

    @Test fun replacingAStyledWordKeepsItsStyle() {
        val r = rich().withText("Title line\nCheck\nStrong word\nEnd")
        assertEquals(listOf(17 to 23), find(r, "span/bold"))
    }

    @Test fun newLineInAChecklistCreatesAnotherCheckbox() {
        val r = rich().withText("Title line\nCheck\nCheck two\nBold word\nEnd")
        assertEquals(listOf(10 to 16, 16 to 26), find(r, "paragraph/bullet"))
        assertEquals(listOf(0 to 10, 10 to 16, 16 to 26, 26 to 36, 36 to 40), find(r, "paragraph/parsingState"))
        val again = RichText.parse(r.encode(), r.spanOrderData())
        assertEquals(simple(r), simple(again))
    }

    @Test fun normalisesValuesNativeParsersRejected() {
        val legacy = RichText.parse(payload("'span/fontSize'='1,12' 'paragraph/parsingState'='False'", "x", "'span/fontSize' 'paragraph/parsingState'", ""))
        val fixed = legacy.normalizedForUpload()
        assertEquals("1,12.0", fixed.ranges.first { it.key == "span/fontSize" }.value)
        assertEquals("false", fixed.ranges.first { it.key == "paragraph/parsingState" }.value)
    }

    @Test fun unknownSpansNeedTheirOrderRecord() {
        val withRecord = RichText.parse(payload("'span/futureStyle'='1,x'", "ab", "'span/futureStyle'", ""), listOf(record("42,0,2,1,x")))
        assertEquals(listOf("42,0,3,1,x"), withRecord.withText("abc").spanOrderData().map { String(base64Decode(it)!!) })
        val without = RichText.parse(payload("'span/futureStyle'='1,x'", "ab", "'span/futureStyle'", ""))
        assertThrows(NotesException::class.java) { without.withText("abc").spanOrderData() }
    }

    @Test fun rejectsMarkupItCannotModel() {
        for (bad in listOf(payload("'span/bold'", "x"), payload("'span/bold'='1,True' junk", "x"), payload("b 'span/bold'='1'", "x"))) {
            assertThrows(NotesException::class.java) { RichText.parse(bad) }
        }
    }

    @Test fun surrogatePairsAreNeverSplit() {
        val r = RichText.parse(payload("'span/bold'='1,True'", "a🚀b", "'span/bold'", ""))
        val edited = r.withText("a🚀🚀b")
        val range = edited.ranges.first()
        assertTrue(!edited.text[range.start].isLowSurrogate() && (range.end == edited.text.length || !edited.text[range.end].isLowSurrogate()))
        assertEquals("a🚀🚀b", RichText.parse(edited.encode()).text)
    }

    /** Characters that survive an edit keep exactly the span styles they had. */
    @Test fun randomEditsPreserveUntouchedStyling() {
        val random = Random(1234)
        val alphabet = "abc \n日🚀"
        repeat(300) {
            val base = rich()
            var current = text
            repeat(1 + random.nextInt(4)) {
                val at = random.nextInt(current.length + 1)
                val remove = minOf(random.nextInt(4), current.length - at)
                val insert = buildString { repeat(random.nextInt(5)) { append(alphabet[random.nextInt(alphabet.length)]) } }
                current = current.substring(0, at) + insert + current.substring(at + remove)
            }
            current = current.replace(Regex("[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]"), "")
            val edited = base.withText(current)
            val origin = TextDiff.origins(text, current)
            for (i in origin.indices) assertTrue(i == 0 || origin[i] >= origin[i - 1])
            for (range in edited.ranges) assertTrue(range.start in 0..range.end && range.end <= current.length)
            // Per key, ranges never overlap (FIFO and LIFO readers agree).
            for ((_, list) in edited.ranges.filter { it.end > it.start }.groupBy { it.key }) {
                val sorted = list.sortedBy { it.start }
                for (i in 1 until sorted.size) assertTrue(sorted[i].start >= sorted[i - 1].end)
            }
            val again = RichText.parse(edited.encode(), edited.normalizedForUpload().spanOrderData())
            assertEquals(current, again.text)
            assertEquals(simple(edited), simple(again))
            // Untouched text before the first and after the last change keeps its exact spans.
            var head = 0
            while (head < text.length && head < current.length && text[head] == current[head]) head++
            var tail = 0
            while (tail < text.length - head && tail < current.length - head && text[text.length - 1 - tail] == current[current.length - 1 - tail]) tail++
            fun spans(r: RichText, at: Int) = r.ranges.filter { it.isSpan && at >= it.start && at < it.end }.map { it.key to it.value }.toSet()
            for (i in 0 until head) assertEquals("prefix $i of '$current'", spans(base, i), spans(edited, i))
            for (i in 1..tail) assertEquals("suffix $i of '$current'", spans(base, text.length - i), spans(edited, current.length - i))
        }
    }

    @Test fun deletingAChecklistLineTakesItsCheckboxAlong() {
        for (edit in listOf("Title line\nBold word\nEnd", "Title line\n\nBold word\nEnd".replaceFirst("\n\n", "\n"))) {
            val r = rich().withText(edit)
            assertTrue(edit, find(r, "paragraph/bullet").isEmpty())
            assertEquals(listOf(10 to 20, 20 to 24), find(r, "paragraph/parsingState").takeLast(2))
        }
        // Deleting just the line break merges "Check" into the title paragraph, which keeps its own style.
        val merged = rich().withText("Title lineCheck\nBold word\nEnd")
        assertTrue(find(merged, "paragraph/bullet").isEmpty())
        assertEquals(listOf(0 to 15, 15 to 25, 25 to 29), find(merged, "paragraph/parsingState"))
    }

    @Test fun cloudDocumentKeepsFormattingWhenSaving() {
        val orderXml = order.joinToString("") { "<spanOrderData val=\"$it\"/>" }
        val xml = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><spanOrderDataList>$orderXml</spanOrderDataList><zeroLengthSpanList/><text>$encoded</text></object></bodyText></noteResource><commitId>c</commitId><downloadUrls/></CompareNoteView>"
        val doc = CloudDocument("note", xml.toByteArray())
        assertNotNull(doc.richBody)
        assertNull(doc.editIssue)
        val uploaded = XmlDocument(doc.uploadXml("", "Title line\nCheck\nBold words\nEnd")).rootElement()!!
        val obj = uploaded.first("bodyText")!!.first("object")!!
        val values = obj.first("spanOrderDataList")!!.elements("spanOrderData").map { it.attr("val") }
        val saved = RichText.parse(obj.value("text"), values)
        assertEquals("Title line\nCheck\nBold words\nEnd", saved.text)
        assertEquals(listOf(17 to 21), find(saved, "span/bold"))
        assertEquals(listOf(10 to 16), find(saved, "paragraph/bullet"))
        assertEquals("5,17,21,1,True", String(base64Decode(values[2])!!))
    }

    @Test fun unsupportedMarkupMakesTheBodyReadOnly() {
        val bad = payload("'span/bold'='1,True' junk", "Text", "'span/bold'", "")
        val xml = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><text>$bad</text></object></bodyText></noteResource><commitId>c</commitId><downloadUrls/></CompareNoteView>"
        val doc = CloudDocument("note", xml.toByteArray())
        assertEquals("Text", doc.body)
        assertNotNull(doc.editIssue)
        assertThrows(NotesException::class.java) { doc.uploadXml("", "Changed") }
    }

    /**
     * Opt-in check against real downloaded documents, never committed:
     * `SCN_RICH_FIXTURES=<folder of CompareNoteView XML files> ./gradlew :app:testDebugUnitTest`.
     */
    @Test fun realDocumentsRoundTrip() {
        val folder = System.getenv("SCN_RICH_FIXTURES")?.let(::File)?.takeIf { it.isDirectory } ?: return
        val files = folder.listFiles { file -> file.name.endsWith(".xml") }!!.sortedBy { it.name }
        var checked = 0
        for (file in files) {
            val doc = try { CloudDocument("fixture", file.readBytes()) } catch (_: NotesException) { continue }
            val obj = doc.bodyObject ?: continue
            if (doc.body.isEmpty()) continue
            assertNotNull("${file.name}: ${doc.formattingIssue}", doc.richBody)
            val rich = doc.richBody!!
            val original = obj.first("spanOrderDataList")?.elements("spanOrderData")?.map { it.attr("val") } ?: emptyList()
            val again = RichText.parse(rich.encode(), rich.spanOrderData())
            assertEquals(file.name, simple(rich), simple(again))
            for (range in rich.ranges.filter { it.isParagraph && it.end > it.start }) {
                assertTrue("${file.name}: ${range.key} starts mid-paragraph", range.start == 0 || rich.text[range.start] == '\n')
                assertTrue("${file.name}: ${range.key} ends mid-paragraph", range.end == rich.text.length || rich.text[range.end] == '\n')
            }
            // In consistent documents every spanOrderData record belongs to exactly one span
            // and the order is reproduced. Pre-1.1.1 uploads left stale records behind.
            if (!doc.bodyNeedsNativeRepair) {
                assertEquals(file.name, original.size, rich.ranges.count { it.typeId != null })
                assertEquals(file.name, original, rich.spanOrderData())
            } else assertTrue(file.name, rich.hasOnlyDefaultStyling)
            val edited = rich.withText(rich.text.substring(0, rich.text.length / 2) + "\nInserted line" + rich.text.substring(rich.text.length / 2))
            val reparsed = RichText.parse(edited.encode(), edited.normalizedForUpload().spanOrderData())
            assertEquals(file.name, edited.text, reparsed.text)
            val upload = doc.uploadXml(doc.title, edited.text)
            assertTrue(upload.isNotEmpty())
            checked++
        }
        println("Real rich-text fixtures checked: $checked of ${files.size}")
    }
}
