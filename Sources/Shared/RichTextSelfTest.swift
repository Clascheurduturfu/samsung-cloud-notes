import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Offline rich-text checks; mirrors android/app/src/test/.../RichTextTest.kt.
enum RichTextSelfTest {
    private static func fail(_ message: String) -> Error { NotesError.message("Rich text: " + message) }
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws { if !condition { throw fail(message()) } }

    /// Samsung-style payload: `parts` alternate between marker bodies and plain text.
    private static func payload(_ parts: String...) -> String {
        var out = ""
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 { if !part.isEmpty { out += "<?a \(part)?>" } } else { out += Data(part.utf8).base64EncodedString() }
        }
        return Data(out.utf8).base64EncodedString()
    }
    private static func record(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
    private static func decoded(_ value: String) -> String { Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    static let text = "Title line\nCheck\nBold word\nEnd"
    static let encoded = payload(
        "'paragraph/alignment'='0' 'paragraph/alignment' 'span/fontSize'='1,15.0' 'span/foregroundColor'='1,-14342875' 'paragraph/parsingState'='false' 'sectionData/sectionData'='30'", "Title line",
        "'paragraph/parsingState' 'paragraph/parsingState'='false' 'paragraph/bullet'='checker,0'", "\nCheck",
        "'paragraph/parsingState' 'paragraph/bullet' 'paragraph/parsingState'='false'", "\n",
        "'span/bold'='1,True'", "Bold",
        "'span/bold' 'span/foregroundColor' 'span/foregroundColor'='-65536'", " word",
        "'span/foregroundColor' 'span/foregroundColor'='1,-14342875' 'paragraph/parsingState' 'paragraph/parsingState'='false'", "\nEnd",
        "'span/fontSize' 'span/foregroundColor' 'paragraph/parsingState' 'sectionData/sectionData'", "",
        "'sectionData/sectionData'='0' 'sectionData/sectionData'", ""
    )
    static let order = ["3,0,30,1,15.0", "1,0,21,1,-14342875", "5,17,21,1,True", "1,21,26,-65536", "1,26,30,1,-14342875"].map(record)

    private static func rich() throws -> RichText { try RichText.parse(encoded, orderData: order) }
    private static func find(_ r: RichText, _ key: String) -> [[Int]] { r.ranges.filter { $0.key == key && !$0.isEmpty }.map { [$0.start, $0.end] } }
    private static func simple(_ r: RichText) -> [String] { r.ranges.map { "\($0.key)|\($0.value)|\($0.start)|\($0.end)" }.sorted() }

    static func run() throws {
        let r = try rich()
        try check(r.text == text && (try StyledText.decode(encoded)) == text, "parsed text")
        try check(find(r, "span/bold") == [[17, 21]] && find(r, "paragraph/bullet") == [[10, 16]], "parsed ranges")
        try check(find(r, "paragraph/parsingState") == [[0, 10], [10, 16], [16, 26], [26, 30]], "paragraph ranges")
        try check(r.ranges.filter { $0.typeID != nil }.count == 5, "spanOrderData matching")

        // Lossless re-encoding with the original span order.
        let again = try RichText.parse(r.encode(), orderData: try r.spanOrderData())
        try check(simple(again) == simple(r) && (try r.spanOrderData()) == order, "lossless re-encoding")

        // Typing inside and after a span extends it; typing before shifts it.
        let typed = r.withText("Title line\nCheck\nBoold word!\nEnd")
        try check(find(typed, "span/bold") == [[17, 22]], "insertion inside a span")
        try check(typed.ranges.first { $0.key == "sectionData/sectionData" && !$0.isEmpty }?.value == "32", "section length")
        try check(find(r.withText("Title line\nCheck\nVery Bold word\nEnd"), "span/bold") == [[22, 26]], "insertion before a span")
        let first = r.withText("New " + text)
        try check(find(first, "span/fontSize") == [[0, 34]] && find(first, "span/bold") == [[21, 25]], "insertion at the start")

        // Deleting or replacing styled words.
        let deleted = r.withText("Title line\nCheck\n word\nEnd")
        try check(find(deleted, "span/bold").isEmpty && find(deleted, "paragraph/bullet") == [[10, 16]], "deleting a styled word")
        try check((try deleted.normalizedForUpload().spanOrderData()).map(decoded) == ["3,0,26,1,15.0", "1,0,17,1,-14342875", "1,17,22,-65536", "1,22,26,1,-14342875"], "order data after deletion")
        try check(find(r.withText("Title line\nCheck\nStrong word\nEnd"), "span/bold") == [[17, 23]], "replacing a styled word")

        // Checklists: Enter continues the list, deleting a line takes its checkbox along,
        // and a merged paragraph keeps the first paragraph's style.
        let listed = r.withText("Title line\nCheck\nCheck two\nBold word\nEnd")
        try check(find(listed, "paragraph/bullet") == [[10, 16], [16, 26]], "new checklist line")
        try check(find(listed, "paragraph/parsingState") == [[0, 10], [10, 16], [16, 26], [26, 36], [36, 40]], "new paragraph state")
        try check(simple(try RichText.parse(listed.encode(), orderData: try listed.spanOrderData())) == simple(listed), "checklist re-encoding")
        let removed = r.withText("Title line\nBold word\nEnd")
        try check(find(removed, "paragraph/bullet").isEmpty && Array(find(removed, "paragraph/parsingState").suffix(2)) == [[10, 20], [20, 24]], "deleted checklist line")
        let merged = r.withText("Title lineCheck\nBold word\nEnd")
        try check(find(merged, "paragraph/bullet").isEmpty && find(merged, "paragraph/parsingState") == [[0, 15], [15, 25], [25, 29]], "merged paragraphs")

        // Legacy values are normalised; unknown spans need their order record.
        let legacy = try RichText.parse(payload("'span/fontSize'='1,12' 'paragraph/parsingState'='False'", "x", "'span/fontSize' 'paragraph/parsingState'", "")).normalizedForUpload()
        try check(legacy.ranges.first { $0.key == "span/fontSize" }?.value == "1,12.0" && legacy.ranges.first { $0.key == "paragraph/parsingState" }?.value == "false", "legacy normalisation")
        let future = payload("'span/futureStyle'='1,x'", "ab", "'span/futureStyle'", "")
        try check((try RichText.parse(future, orderData: [record("42,0,2,1,x")]).withText("abc").spanOrderData()).map(decoded) == ["42,0,3,1,x"], "unknown span with record")
        try check((try? RichText.parse(future).withText("abc").spanOrderData()) == nil, "unknown span without record")
        for bad in [payload("'span/bold'", "x"), payload("'span/bold'='1,True' junk", "x"), payload("b 'span/bold'='1'", "x")] {
            try check((try? RichText.parse(bad)) == nil, "unsupported markup accepted")
        }

        // Surrogate pairs are never split.
        let emoji = try RichText.parse(payload("'span/bold'='1,True'", "a🚀b", "'span/bold'", "")).withText("a🚀🚀b")
        let units = Array(emoji.text.utf16)
        try check(emoji.ranges.allSatisfy { !UTF16.isTrailSurrogate(units[$0.start]) && ($0.end == units.count || !UTF16.isTrailSurrogate(units[$0.end])) }, "surrogate boundary")
        try check((try RichText.parse(emoji.encode())).text == "a🚀🚀b", "surrogate text")

        try randomEdits(r)
        try cloudDocument()
    }

    /// Deterministic fuzz: untouched text keeps its exact spans and output always re-parses.
    private static func randomEdits(_ base: RichText) throws {
        var seed: UInt64 = 1234
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        let alphabet = Array("abc \n日🚀")
        let original = Array(text.utf16)
        for _ in 0..<200 {
            var current = Array(text)
            for _ in 0..<(1 + next(4)) {
                let at = next(current.count + 1)
                let remove = min(next(4), current.count - at)
                let insert = (0..<next(5)).map { _ in alphabet[next(alphabet.count)] }
                current.replaceSubrange(at..<(at + remove), with: insert)
            }
            let newText = String(current)
            let edited = base.withText(newText)
            let units = Array(newText.utf16)
            let origin = TextDiff.origins(original, units)
            try check(origin.indices.allSatisfy { $0 == 0 || origin[$0] >= origin[$0 - 1] }, "origins decreased")
            try check(edited.ranges.allSatisfy { $0.start >= 0 && $0.start <= $0.end && $0.end <= units.count }, "range bounds")
            for (_, list) in Dictionary(grouping: edited.ranges.filter { !$0.isEmpty }, by: \.key) {
                let sorted = list.sorted { $0.start < $1.start }
                try check(zip(sorted, sorted.dropFirst()).allSatisfy { $1.start >= $0.end }, "overlapping ranges")
            }
            let again = try RichText.parse(edited.encode(), orderData: try edited.normalizedForUpload().spanOrderData())
            try check(again.text == newText && simple(again) == simple(edited), "fuzz re-encoding")
            var head = 0
            while head < original.count && head < units.count && original[head] == units[head] { head += 1 }
            var tail = 0
            while tail < original.count - head && tail < units.count - head && original[original.count - 1 - tail] == units[units.count - 1 - tail] { tail += 1 }
            func spans(_ r: RichText, _ at: Int) -> Set<String> { Set(r.ranges.filter { $0.isSpan && at >= $0.start && at < $0.end }.map { $0.key + "=" + $0.value }) }
            for i in 0..<head { try check(spans(base, i) == spans(edited, i), "prefix styling changed") }
            if tail > 0 { for i in 1...tail { try check(spans(base, original.count - i) == spans(edited, units.count - i), "suffix styling changed") } }
        }
    }

    private static func cloudDocument() throws {
        let orderXML = order.map { "<spanOrderData val=\"\($0)\"/>" }.joined()
        func wrap(_ body: String, _ list: String) -> String {
            "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\">\(list)<zeroLengthSpanList/><text>\(body)</text></object></bodyText></noteResource><commitId>c</commitId><downloadUrls/></CompareNoteView>"
        }
        let doc = try CloudDocument(serverID: "note", data: Data(wrap(encoded, "<spanOrderDataList>\(orderXML)</spanOrderDataList>").utf8))
        try check(doc.richBody != nil && doc.editIssue == nil, "formatted note not editable")
        let upload = try XMLDocument(data: doc.uploadXML(title: "", body: "Title line\nCheck\nBold words\nEnd"))
        guard let object = upload.rootElement()?.first("bodyText")?.first("object") else { throw fail("upload lost the body object") }
        let values = object.first("spanOrderDataList")?.elements(forName: "spanOrderData").map { $0.attr("val") } ?? []
        let saved = try RichText.parse(object.value("text"), orderData: values)
        try check(saved.text == "Title line\nCheck\nBold words\nEnd" && find(saved, "span/bold") == [[17, 21]] && find(saved, "paragraph/bullet") == [[10, 16]], "saved formatting")
        try check(values.count == 5 && decoded(values[2]) == "5,17,21,1,True", "saved span order")

        let bad = payload("'span/bold'='1,True' junk", "Text", "'span/bold'", "")
        let readOnly = try CloudDocument(serverID: "note", data: Data(wrap(bad, "").utf8))
        try check(readOnly.body == "Text" && readOnly.editIssue != nil, "unsupported markup not read-only")
        try check((try? readOnly.uploadXML(title: "", body: "Changed")) == nil, "unsupported markup was rewritten")
    }
}
