import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Samsung pictures, tables and drawings as Apple Notes attachments (one way:
// Samsung → Apple). Samsung marks each inline object with U+FFFC in the body text
// and an 'objectSpan' range naming the object; Apple uses the same character with
// an attachment run. Drawings (handwriting pages) become pictures at the end.

/// One attachment to write into Apple Notes.
struct AppleAttachment {
    enum Kind { case image(Data, uti: String, fileName: String, width: Double, height: Double), table([[String]]) }
    let identifier: String
    let kind: Kind
    init(_ kind: Kind, identifier: String = UUID().uuidString) { self.kind = kind; self.identifier = identifier }

    var uti: String {
        switch kind {
        case .image(_, let uti, _, _, _): return uti
        case .table: return "com.apple.notes.table"
        }
    }
    var isTable: Bool { if case .table = kind { return true }; return false }
}

// MARK: - Samsung objects (SamsungTable, anchors: Shared/NoteObjects.swift)

extension SamsungAttachments {
    static func uti(_ data: Data) -> (uti: String, width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0 else { return nil }
        let supported = ["public.jpeg", "public.png", "public.heic", "com.compuserve.gif", "public.tiff", "org.webmproject.webp", "com.microsoft.bmp"]
        guard supported.contains(type) else { return nil }
        var w = width, h = height
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 { swap(&w, &h) }
        return (type, w, h)
    }

    static func fileName(_ raw: String, uti: String) -> String {
        let ext = UTType(uti)?.preferredFilenameExtension ?? "img"
        var name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.hasPrefix(".") { name = "Picture." + ext }
        if (name as NSString).pathExtension.isEmpty { name += "." + ext }
        return String(name.suffix(120))
    }

    /// A handwriting page cropped to its ink, as a PNG.
    static func drawing(_ source: DrawingPage, scale: CGFloat = 2) -> AppleAttachment? {
        var page = source
        // Transparent pages get a solid background that contrasts with the ink, so it shows in light and dark mode.
        if (page.background >> 24) & 0xff < 128 {
            let tones = page.strokes.map { stroke -> Double in
                let c = stroke.color
                return (0.299 * Double((c >> 16) & 0xff) + 0.587 * Double((c >> 8) & 0xff) + 0.114 * Double(c & 0xff)) / 255
            }
            let light = !tones.isEmpty && tones.reduce(0, +) / Double(tones.count) > 0.6
            page.background = light ? 0xFF1C_1C1E : 0xFFFF_FFFF
        }
        let points = page.strokes.flatMap { stroke in stroke.points.map { CGRect(x: $0.x, y: $0.y, width: 0, height: 0).insetBy(dx: -stroke.width, dy: -stroke.width) } }
        guard var bounds = points.first else { return nil }
        for rect in points.dropFirst() { bounds = bounds.union(rect) }
        bounds = bounds.insetBy(dx: -16, dy: -16).intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height)).integral
        guard bounds.width >= 4, bounds.height >= 4, bounds.width * bounds.height * scale * scale <= 64_000_000,
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(in: context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return AppleAttachment(.image(data as Data, uti: "public.png", fileName: "Drawing \(page.id + 1).png",
                                      width: Double(image.width), height: Double(image.height)))
    }

    /// Resolves a note's inline objects (one entry per U+FFFC in its body) and drawings.
    static func resolve(_ document: CloudDocument, load: (AssetRecord) async -> Data?) async -> (inline: [AppleAttachment?], drawings: [AppleAttachment]) {
        var inline: [AppleAttachment?] = []
        if let rich = document.richBody, rich.text == StyledText.normalized(document.body) {
            let objects = sources(document)
            for anchor in anchors(rich) {
                switch anchor.flatMap({ objects[$0] }) {
                case .image(let asset):
                    guard let data = await load(asset), data.count <= 200_000_000, let info = uti(data) else { inline.append(nil); continue }
                    inline.append(AppleAttachment(.image(data, uti: info.uti, fileName: fileName(asset.fileName, uti: info.uti), width: info.width, height: info.height)))
                case .table(let cells):
                    inline.append(AppleAttachment(.table(cells)))
                case nil: inline.append(nil)
                }
            }
        }
        let drawings = document.drawingPages.filter { !$0.strokes.isEmpty }.compactMap { drawing($0) }
        return (inline, drawings)
    }
}

// MARK: - Apple table (com.apple.notes.table)

/// Builds Apple's CRDT table document; mirrors what Notes writes for a fresh single-replica table.
enum AppleTable {
    indirect enum Value { case int(Int), bytes(Data), message([(Int, Value)]) }
    typealias Message = [(Int, Value)]

    static func encode(_ message: Message) -> Data {
        var writer = ProtoWriter()
        for (field, value) in message {
            switch value {
            case .int(let n): writer.int(field, n)
            case .bytes(let d): writer.bytes(field, d)
            case .message(let m): writer.bytes(field, encode(m))
            }
        }
        return writer.data
    }

    static let keys = ["identity", "cellColumns", "UUIDIndex", "crRows", "crColumns", "crTableColumnDirection", "self"]
    static let types = ["com.apple.CRDT.NSNumber", "com.apple.CRDT.NSString", "com.apple.CRDT.NSUUID", "com.apple.CRDT.CRTuple",
                        "com.apple.CRDT.CRRegisterMultiValueLeast", "com.apple.CRDT.CRRegisterMultiValue", "com.apple.CRDT.CRTree",
                        "com.apple.CRDT.CRTreeNode", "com.apple.CRDT.NSData", "com.apple.CRDT.NSDate",
                        "com.apple.notes.ICCloudSyncingObjectActivityEvent", "com.apple.notes.ICFastSyncSelectionState",
                        "com.apple.notes.ICTTAudioRecording", "com.apple.notes.ICTTAudioRecording.Fragment",
                        "com.apple.notes.ICTTTranscriptSegment", "com.apple.notes.CRTable", "com.apple.notes.ICTable"]

    static func data(_ rows: [[String]], replica: UUID = UUID(), now: Date = Date()) throws -> (data: Data, summary: String) {
        let width = rows.map(\.count).max() ?? 0
        guard !rows.isEmpty, width > 0 else { throw NotesError.message("Empty table.") }
        let rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        let timestamp = Int(now.timeIntervalSince1970)
        func key(_ name: String) -> Value { .int(keys.firstIndex(of: name)!) }
        func type(_ name: String) -> Value { .int(types.firstIndex(of: name)!) }
        func string(_ s: String) -> Value { .bytes(Data(s.utf8)) }
        func id() -> Data { withUnsafeBytes(of: UUID().uuid) { Data($0) } }
        let stamp: Value = .message([(1, .message([(1, .int(0)), (2, .int(1))]))])
        var uuids: [Data] = [withUnsafeBytes(of: replica.uuid) { Data($0) }]
        var objects: [Message?] = []
        func add(_ entry: Message? = nil) -> Int { objects.append(entry); return objects.count - 1 }
        func ref(_ index: Int) -> Value { .message([(6, .int(index))]) }
        func nsuuid(_ bytes: Data) -> Int {
            uuids.append(bytes)
            return add([(13, .message([(1, type("com.apple.CRDT.NSUUID")), (3, .message([(1, key("UUIDIndex")), (2, .message([(2, .int(uuids.count - 1))]))]))]))])
        }
        func topotext(_ text: String, clockStart: Int) -> Message {
            let n = text.utf16.count
            return [(2, string(text)),
                    (3, .message([(1, .message([(1, .int(0)), (2, .int(0))])), (2, .int(0)), (3, .message([(1, .int(0)), (2, .int(0))])), (5, .int(1))])),
                    (3, .message([(1, .message([(1, .int(1)), (2, .int(clockStart))])), (2, .int(n)), (3, .message([(1, .int(1)), (2, .int(0))])), (5, .int(2))])),
                    (3, .message([(1, .message([(1, .int(0)), (2, .int(0xFFFF_FFFF))])), (2, .int(0)), (3, .message([(1, .int(0)), (2, .int(0xFFFF_FFFF))]))]))]
        }
        var clock = 0
        func text(_ value: String) -> Int {
            var topo = topotext(value, clockStart: clock + 1)
            let n = value.utf16.count
            clock += n
            if n > 0 { topo.append((5, .message([(1, .int(n)), (2, .message([(9, .bytes(id()))])), (13, .int(timestamp))]))) }
            return add([(10, .message(topo))])
        }
        func orderedSet(_ ids: [(object: Int, uuid: Int)], _ items: [Int]) -> Message {
            var array: Message = topotext(String(repeating: "\u{FFFC}", count: ids.count), clockStart: 0)
            array += ids.map { _ in (5, .message([(1, .int(1))])) }
            let list: Message = [(1, .message(array))] + ids.indices.map { i in (2, .message([(1, .int(i)), (2, .bytes(uuids[ids[i].uuid]))])) }
            let contents: Message = ids.indices.map { i in (1, .message([(1, ref(ids[i].object)), (2, ref(items[i])), (3, stamp)])) }
            let elements: Message = ids.map { (1, .message([(1, ref($0.object)), (2, ref($0.object)), (3, stamp)])) }
            return [(16, .message([(1, .message([(1, .message(list)), (2, .message(contents))])), (2, .message(elements))]))]
        }
        func ordering(_ count: Int) -> [(object: Int, uuid: Int)] { (0..<count).map { _ in (nsuuid(id()), uuids.count - 1) } }

        let root = add()
        let rowObjects = rows.indices.map { _ in nsuuid(id()) }
        let columnObjects = (0..<width).map { _ in nsuuid(id()) }
        var columnDictionaries: [Int] = []
        for c in 0..<width {
            var cells: Message = []
            for r in rows.indices { let cell = text(rows[r][c]); cells.append((1, .message([(1, ref(rowObjects[r])), (2, ref(cell)), (3, stamp)]))) }
            columnDictionaries.append(add([(6, .message(cells))]))
        }
        let cellColumns = add([(6, .message((0..<width).map { c in (1, .message([(1, ref(columnObjects[c])), (2, ref(columnDictionaries[c])), (3, stamp)])) }))])
        let rowSet = add(); objects[rowSet] = orderedSet(ordering(rows.count), rowObjects)
        let columnSet = add(); objects[columnSet] = orderedSet(ordering(width), columnObjects)
        let directionString = add([(13, .message([(1, type("com.apple.CRDT.NSString")), (3, .message([(1, key("self")), (2, .message([(4, string("CRTableColumnDirectionLeftToRight"))]))]))]))])
        let direction = add([(1, .message([(1, .message([(1, .int(0)), (2, .int(1))])), (2, ref(directionString))]))])
        objects[root] = [(13, .message([(1, type("com.apple.notes.ICTable")),
                                        (3, .message([(1, key("identity")), (2, .message([(4, string("00000000-0000-0000-0000-000000000000"))]))])),
                                        (3, .message([(1, key("cellColumns")), (2, ref(cellColumns))])),
                                        (3, .message([(1, key("crRows")), (2, ref(rowSet))])),
                                        (3, .message([(1, key("crColumns")), (2, ref(columnSet))])),
                                        (3, .message([(1, key("crTableColumnDirection")), (2, ref(direction))]))]))]
        var document: Message = [(1, .message([(1, .message([(1, .int(0)), (2, .int(1))]))])), (2, .bytes(Data()))]
        document += objects.map { (3, .message($0 ?? [])) }
        document += keys.map { (4, string($0)) } + types.map { (5, string($0)) } + uuids.map { (6, .bytes($0)) }
        document.append((7, .message([(1, .message([(1, .bytes(uuids[0])), (2, .message([(1, .int(clock))])), (2, .message([(1, .int(2))]))]))])))
        let wrapped: Message = [(1, .int(0)), (2, .message([(1, .int(0)), (2, .int(0)), (3, .message(document))]))]
        return (try Gzip.compress(encode(wrapped)), rows.flatMap { $0 }.joined(separator: "\n"))
    }
}

// MARK: - Self-test

extension AppleNotesSelfTest {
    /// A synthetic Samsung table record: header object, then cells with rectangles and text.
    static func samsungTable(_ cells: [(left: Double, top: Double, text: String)]) -> Data {
        var data = Data([0xff, 0xff, 0xff, 0xff, 4, 0, 0, 0])
        func object() { data.append(contentsOf: [36, 0]); data.append(contentsOf: Array(UUID().uuidString.lowercased().utf8)) }
        func double(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        object(); data.append(contentsOf: [UInt8](repeating: 0, count: 40))
        for cell in cells {
            object(); data.append(contentsOf: [UInt8](repeating: 0, count: 8))
            double(cell.left); double(cell.top); double(cell.left + 100); double(cell.top + 50)
            data.append(contentsOf: [0, 0, 0x49, 0, 6, 0])
            let units = Array(cell.text.utf16)
            u32(135 + 2 * units.count); u32(units.count)
            for unit in units { withUnsafeBytes(of: unit.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: [2, 0, 0, 0, 0x18, 0])
        }
        return data
    }

    static func testImage() -> Data {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func attachments() throws {
        let cells = SamsungTable.cells(samsungTable([(33, 41, "1"), (361, 41, "23"), (33, 97.5, "3"), (361, 97.5, "")]))
        guard cells == [["1", "23"], ["3", ""]] else { throw NotesError.message("Samsung table parse mismatch: \(String(describing: cells))") }
        let table = try AppleTable.data([["a", "b"], ["c"]])
        guard table.summary == "a\nb\nc\n", try Gzip.decompress(table.data).count > 200 else { throw NotesError.message("Apple table encode mismatch.") }
        guard let info = SamsungAttachments.uti(testImage()), info.uti == "public.png", info.width == 8, info.height == 6 else {
            throw NotesError.message("Image type detection failed.")
        }
        // Inline objects and drawings become attachment runs on U+FFFC.
        let image = AppleAttachment(.image(testImage(), uti: "public.png", fileName: "p.png", width: 8, height: 6))
        let export = try AppleExport(title: "Pics", body: "A\n\u{FFFC}\nB", rich: nil, attachments: [AppleAttachment(.table([["x"]]))], drawings: [image])
        guard export.content.text == "Pics\nA\n\u{FFFC}\nB\n\u{FFFC}\n", export.tail == 1, export.attachments.count == 2 else {
            throw NotesError.message("Attachment export mismatch: \(export.content.text.debugDescription)")
        }
        try attachmentLines(image)
        let note = try ProtoReader.parse(ProtoReader.parse(ProtoReader.parse(Gzip.decompress(export.data)).field(2)!.data).field(3)!.data)
        let attached = try note.fields(5).compactMap { try ProtoReader.parse($0.data).field(12) }
        guard attached.count == 2 else { throw NotesError.message("Attachment runs missing: \(attached.count)") }
        // Notes keeps tables in ZMERGEABLEDATA1, not ZMERGEABLEDATA.
        let columns: [String: SQLValue] = ["ZMERGEABLEDATA": .null, "ZMERGEABLEDATA1": .null, "ZMERGEABLEDATA2": .null]
        guard AppleNoteStore.tableDataColumn(template: nil, row: columns) == "ZMERGEABLEDATA1",
              AppleNoteStore.tableDataColumn(template: ["ZMERGEABLEDATA": .null, "ZMERGEABLEDATA1": .blob(Data([1]))], row: columns) == "ZMERGEABLEDATA1" else {
            throw NotesError.message("Table data column mismatch.")
        }
        try merges()
        // The app's editor shows tables and pictures in place.
        guard let grid = RichObjects.table([["1", "23"], ["3", "4"]], size: 15), grid.size.width > 60, grid.size.height > 30,
              RichObjects.attachment(.image(testImage()), baseSize: 15)?.bounds.size == CGSize(width: 8, height: 6) else {
            throw NotesError.message("Inline table or picture could not be drawn.")
        }
    }

    /// Notes keeps each attachment on a line of its own and rewrites notes that do not. The export does
    /// the same, Notes' own rewrite counts as no edit, and those line breaks never reach Samsung.
    static func attachmentLines(_ image: AppleAttachment) throws {
        let plain = try RichText.parse(RichTextSelfTest.encoded, orderData: RichTextSelfTest.order)
        let (inline, objects) = withObjects(plain, inline: true)
        let doc = try document("i1", body: inline, objects: objects)
        let export = try AppleExport(title: doc.title, body: doc.body, rich: doc.richBody, attachments: [image, AppleAttachment(.table([["x"]]))])
        let content = export.content
        guard content.text == "Shopping\n" + plain.text + "\n\u{FFFC}\nafter picture\n\u{FFFC}\n", content.standalone == content,
              case .unchanged = AppleExport.samsungDraft(content, titleLine: true, document: doc) else {
            throw NotesError.message("Attachment line layout mismatch: \(content.text.debugDescription)")
        }
        // What Notes made of a 1.2.0-beta.4 copy: a break after the picture only, and one at the end.
        let lines = content.text.components(separatedBy: "\n")
        guard let picture = lines.firstIndex(of: AppleNoteContent.attachment) else { throw NotesError.message("Picture line missing.") }
        var checks = content.checks; checks.remove(at: picture)
        let notes = AppleNoteContent(text: content.text.replacingOccurrences(of: "\n\u{FFFC}\nafter", with: "\u{FFFC}\nafter"), checks: checks)
        let older = AppleNoteContent(text: "Shopping\n" + inline.text, checks: Array(checks.dropLast(2)))
        guard notes.standalone == content, older.standalone == content,
              case .unchanged = AppleExport.samsungDraft(notes, titleLine: true, document: doc) else {
            throw NotesError.message("Notes' attachment lines were taken as an edit: \(notes.standalone.text.debugDescription)")
        }
        // A tick made in Notes reaches Samsung without the extra line breaks.
        var ticked = content
        if let open = ticked.checks.firstIndex(of: false) { ticked.checks[open] = true }
        guard case .draft(let draft) = AppleExport.samsungDraft(ticked, titleLine: true, document: doc), draft.body == doc.body,
              draft.rich?.withText(draft.body).checkStates.contains(true) == true,
              SamsungAttachments.anchors(draft.rich ?? inline) == ["obj-img", "obj-tab"] else {
            throw NotesError.message("A tick next to an inline picture was not brought back cleanly.")
        }
    }

    /// Edits made on both sides since the last sync.
    static func merges() throws {
        func c(_ lines: [(String, Bool?)]) -> AppleNoteContent { AppleNoteContent(text: lines.map { $0.0 }.joined(separator: "\n"), checks: lines.map { $0.1 }) }
        let base = c([("Note", nil), ("Check", true), ("Cheked", false), ("Plain", nil)])
        // Ticked in Apple, a line added on the phone.
        guard AppleNoteContent.merge(base: base, apple: c([("Note", nil), ("Check", true), ("Cheked", true), ("Plain", nil)]),
                                     samsung: c([("Note", nil), ("Check", true), ("Cheked", false), ("New", false), ("Plain", nil)]))
                == c([("Note", nil), ("Check", true), ("Cheked", true), ("New", false), ("Plain", nil)]) else {
            throw NotesError.message("Merge of a tick and an added line failed.")
        }
        // The same tick on both sides plus a phone line: Samsung's version already has everything.
        let phone = c([("Note", nil), ("Check", true), ("Cheked", true), ("why that dont work ?", true), ("Plain", nil)])
        guard AppleNoteContent.merge(base: base, apple: c([("Note", nil), ("Check", true), ("Cheked", true), ("Plain", nil)]), samsung: phone) == phone else {
            throw NotesError.message("Merge of identical ticks failed.")
        }
        // Different lines edited on each side.
        guard AppleNoteContent.merge(base: base, apple: c([("Note", nil), ("Check", true), ("Cheked", false), ("Plain text", nil)]),
                                     samsung: c([("Notes", nil), ("Check", true), ("Cheked", false), ("Plain", nil)]))
                == c([("Notes", nil), ("Check", true), ("Cheked", false), ("Plain text", nil)]) else {
            throw NotesError.message("Merge of separate line edits failed.")
        }
        // The same line edited differently does not merge; an untick on one side and a new line on the other does.
        guard AppleNoteContent.merge(base: base, apple: c([("Note", nil), ("Check", true), ("Cheked", false), ("Mac", nil)]),
                                     samsung: c([("Note", nil), ("Check", true), ("Cheked", false), ("Phone", nil)])) == nil,
              AppleNoteContent.merge(base: base, apple: c([("Note", nil), ("Check", false), ("Cheked", false), ("Plain", nil)]),
                                     samsung: c([("Note", nil), ("Check", true), ("Cheked", false), ("Plain", nil), ("x", nil)])) != nil,
              AppleNoteContent(text: "a\nb", checkString: "-1").checks == [nil, true], base.checkString == "-10-" else {
            throw NotesError.message("Merge conflict detection failed.")
        }
    }
}
