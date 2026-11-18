import Foundation
import AppKit
import SQLite3
import CryptoKit
import UniformTypeIdentifiers

// Apple Notes bridge. Samsung notes are written into Apple Notes' own database
// (NoteStore.sqlite, "On My Mac" account only) as real Notes content: paragraph
// styles, checklists, colours, highlights. Notes must be quit while the store is
// written; it is reopened afterwards. iCloud accounts are never read or written.
//
// Note bodies are gzipped protocol buffers (a CRDT "topotext" string plus
// attribute runs). The format is undocumented; this mirrors what Notes itself
// writes for single-replica notes and was verified against macOS 27.

// MARK: - Protocol buffers

struct ProtoWriter {
    private(set) var data = Data()
    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func int(_ field: Int, _ value: Int) { varint(UInt64(field) << 3); varint(UInt64(truncatingIfNeeded: value)) }
    mutating func bytes(_ field: Int, _ value: Data) { varint(UInt64(field) << 3 | 2); varint(UInt64(value.count)); data.append(value) }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func float(_ field: Int, _ value: Float) {
        varint(UInt64(field) << 3 | 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter(); build(&inner); bytes(field, inner.data)
    }
}

struct ProtoField { var number: Int; var wire: Int; var int: UInt64; var data: Data }

enum ProtoReader {
    static func parse(_ data: Data) throws -> [ProtoField] {
        let b = [UInt8](data)
        var i = 0
        var out: [ProtoField] = []
        func bad() -> Error { NotesError.message("Apple Notes returned note data this version cannot read.") }
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw bad() }
                let c = b[i]; i += 1
                result |= UInt64(c & 0x7f) << shift; shift += 7
                if c < 0x80 { return result }
            }
        }
        while i < b.count {
            let key = try varint()
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: out.append(ProtoField(number: number, wire: 0, int: try varint(), data: Data()))
            case 1, 5:
                let n = wire == 1 ? 8 : 4
                guard i + n <= b.count else { throw bad() }
                out.append(ProtoField(number: number, wire: wire, int: 0, data: Data(b[i..<i + n]))); i += n
            case 2:
                let n = Int(clamping: try varint())
                guard i + n <= b.count else { throw bad() }
                out.append(ProtoField(number: number, wire: 2, int: 0, data: Data(b[i..<i + n]))); i += n
            default: throw bad()
            }
        }
        return out
    }
}

extension Array where Element == ProtoField {
    func field(_ number: Int) -> ProtoField? { first { $0.number == number } }
    func fields(_ number: Int) -> [ProtoField] { filter { $0.number == number } }
}

enum Gzip {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data // raw DEFLATE
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(deflated)
        withUnsafeBytes(of: crc32(data).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }
    static func decompress(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw NotesError.message("Apple Notes data is not gzip.") }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { throw NotesError.message("Apple Notes data is truncated.") }
        return try (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }
}

private func uuidData(_ value: UUID = UUID()) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }

// MARK: - Note content

/// What a note says, as far as sync is concerned: its text and each paragraph's checklist state.
struct AppleNoteContent: Equatable {
    static let attachment = "\u{FFFC}"
    var text: String
    var checks: [Bool?]

    init(text: String, checks: [Bool?]) { self.text = text; self.checks = checks }
    init(text: String, checkString: String) {
        self.text = text
        checks = checkString.map { $0 == "1" ? true : $0 == "0" ? false : nil }
    }

    /// One character per paragraph: "-" no checkbox, "0" open, "1" ticked.
    var checkString: String { checks.map { $0 == nil ? "-" : $0! ? "1" : "0" }.joined() }

    var fingerprint: String {
        SHA256.hash(data: Data((text + "\u{0}" + checkString).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func attachmentOnly(_ line: String) -> Bool { !line.isEmpty && line.unicodeScalars.allSatisfy { $0 == "\u{FFFC}" } }

    /// Notes keeps every attachment on a line of its own, and ends a note that finishes with one with a
    /// line break; it rewrites notes that do not when it opens them. This note in that layout
    /// (attachment lines carry no checkbox).
    var standalone: AppleNoteContent {
        var lines: [(text: String, check: Bool?)] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let check = index < checks.count ? checks[index] : nil
            guard line.unicodeScalars.contains("\u{FFFC}") else { lines.append((line, check)); continue }
            var buffer = ""
            for scalar in line.unicodeScalars {
                guard scalar == "\u{FFFC}" else { buffer.unicodeScalars.append(scalar); continue }
                if !buffer.isEmpty { lines.append((buffer, check)); buffer = "" }
                lines.append((Self.attachment, nil))
            }
            if !buffer.isEmpty { lines.append((buffer, check)) }
        }
        if let last = lines.last, Self.attachmentOnly(last.text) { lines.append(("", nil)) }
        return AppleNoteContent(text: lines.map(\.text).joined(separator: "\n"), checks: lines.map(\.check))
    }

    /// Takes back the line breaks put around attachments (by `standalone` or by Notes) where the
    /// Samsung text `body` has none, so the lines map onto Samsung's paragraphs again.
    static func rejoin(_ lines: [(text: String, check: Bool?)], samsung body: String) -> [(text: String, check: Bool?)] {
        let scalars = Array(body.unicodeScalars)
        var before: [Bool] = [], after: [Bool] = []
        for (i, scalar) in scalars.enumerated() where scalar == "\u{FFFC}" {
            before.append(i > 0 && scalars[i - 1] != "\n")
            after.append(i + 1 == scalars.count || scalars[i + 1] != "\n")
        }
        var out: [(text: String, check: Bool?)] = []
        var seen = 0, joinNext = false
        for line in lines {
            let opens = line.text.unicodeScalars.first == "\u{FFFC}"
            if let last = out.last, joinNext || (opens && seen < before.count && before[seen]) {
                out[out.count - 1] = (last.text + line.text, attachmentOnly(last.text) ? line.check : last.check)
            } else {
                out.append(line)
            }
            seen += line.text.unicodeScalars.filter { $0 == "\u{FFFC}" }.count
            joinNext = line.text.unicodeScalars.last == "\u{FFFC}" && seen > 0 && seen <= after.count && after[seen - 1]
        }
        return out
    }

    /// Three-way merge by paragraph. Edits made since `base` on each side are combined when they
    /// touch different paragraphs (a checkbox ticked on one side counts as its own edit); nil when
    /// both sides changed the same place differently.
    static func merge(base: AppleNoteContent, apple: AppleNoteContent, samsung: AppleNoteContent) -> AppleNoteContent? {
        typealias Line = (text: String, check: Bool?)
        func lines(_ c: AppleNoteContent) -> [Line] {
            c.text.components(separatedBy: "\n").enumerated().map { ($1, $0 < c.checks.count ? c.checks[$0] : nil) }
        }
        func same(_ x: ArraySlice<Line>, _ y: ArraySlice<Line>) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.text == $1.text && $0.check == $1.check }
        }
        let b = lines(base), a = lines(apple), s = lines(samsung)
        guard let toApple = matching(b.map(\.text), a.map(\.text)), let toSamsung = matching(b.map(\.text), s.map(\.text)) else { return nil }
        var out: [Line] = []
        var ib = 0, ia = 0, isam = 0
        // Paragraphs present, unchanged in text, on all three sides anchor the merge; edits sit between them.
        for anchor in b.indices.filter({ toApple[$0] != nil && toSamsung[$0] != nil }) + [b.count] {
            let aEnd = anchor < b.count ? toApple[anchor]! : a.count
            let sEnd = anchor < b.count ? toSamsung[anchor]! : s.count
            let bh = b[ib..<anchor], ah = a[ia..<aEnd], sh = s[isam..<sEnd]
            if same(ah, bh) { out += sh } else if same(sh, bh) || same(ah, sh) { out += ah } else { return nil }
            guard anchor < b.count else { break }
            let was = b[anchor].check, mine = a[aEnd].check, theirs = s[sEnd].check
            let check: Bool?
            if mine == was { check = theirs } else if theirs == was || theirs == mine { check = mine } else { return nil }
            out.append((b[anchor].text, check))
            ib = anchor + 1; ia = aEnd + 1; isam = sEnd + 1
        }
        return AppleNoteContent(text: out.map(\.text).joined(separator: "\n"), checks: out.map(\.check))
    }

    /// For each line of `x`, its partner in `y` in a longest common subsequence (nil when unmatched).
    static func matching(_ x: [String], _ y: [String]) -> [Int?]? {
        let n = x.count, m = y.count, w = m + 1
        guard n * m <= 4_000_000 else { return nil }
        var table = [Int32](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * w + j] = x[i] == y[j] ? table[(i + 1) * w + j + 1] + 1 : max(table[(i + 1) * w + j], table[i * w + j + 1])
            }
        }
        var result = [Int?](repeating: nil, count: n)
        var i = 0, j = 0
        while i < n && j < m {
            if x[i] == y[j] { result[i] = j; i += 1; j += 1 }
            else if table[(i + 1) * w + j] >= table[i * w + j + 1] { i += 1 } else { j += 1 }
        }
        return result
    }

    /// Reads a ZICNOTEDATA.ZDATA blob.
    static func read(_ stored: Data) throws -> AppleNoteContent {
        let raw = stored.starts(with: [0x1f, 0x8b]) ? try Gzip.decompress(stored) : stored
        guard let document = try ProtoReader.parse(raw).field(2),
              let noteField = try ProtoReader.parse(document.data).field(3) else {
            throw NotesError.message("Apple Notes returned a note without text.")
        }
        let note = try ProtoReader.parse(noteField.data)
        let text = note.field(2).map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        var runs: [(end: Int, style: Int?, done: Bool?)] = []
        var position = 0
        for run in note.fields(5) {
            let fields = try ProtoReader.parse(run.data)
            position += Int(fields.field(1)?.int ?? 0)
            var style: Int?, done: Bool?
            if let paragraph = fields.field(2) {
                let p = try ProtoReader.parse(paragraph.data)
                style = p.field(1).map { Int($0.int) }
                if let check = p.field(5) { done = (try ProtoReader.parse(check.data).field(2)?.int ?? 0) != 0 }
            }
            runs.append((position, style, done))
        }
        let units = Array(text.utf16)
        let starts = [0] + units.indices.filter { units[$0] == 10 }.map { $0 + 1 }
        let checks: [Bool?] = starts.map { start in
            guard start < units.count, let run = runs.first(where: { $0.end > start }), run.style == 103 else { return nil }
            return run.done ?? false
        }
        return AppleNoteContent(text: text, checks: checks)
    }
}

/// Builds Apple Notes note data from paragraphs of styled segments.
struct AppleNoteBuilder {
    enum Style: Equatable { case title, body, bullet, number, check(Bool) }
    struct Paragraph { var segments: [RichSegment]; var style: Style = .body; var alignment = 0; var indent = 0 }
    var paragraphs: [Paragraph] = []
    /// Attachment for each U+FFFC in the text, in order; nil leaves the character bare.
    var attachments: [(identifier: String, uti: String)?] = []

    /// `paragraph` with each attachment character on a plain paragraph of its own, as Notes keeps them.
    static func standalone(_ paragraph: Paragraph) -> [Paragraph] {
        guard paragraph.segments.contains(where: { $0.text.unicodeScalars.contains("\u{FFFC}") }) else { return [paragraph] }
        var result: [Paragraph] = [], current: [RichSegment] = []
        func flush() {
            if current.contains(where: { !$0.text.isEmpty }) { var piece = paragraph; piece.segments = current; result.append(piece) }
            current = []
        }
        for segment in paragraph.segments {
            var buffer = ""
            for scalar in segment.text.unicodeScalars {
                guard scalar == "\u{FFFC}" else { buffer.unicodeScalars.append(scalar); continue }
                if !buffer.isEmpty { var part = segment; part.text = buffer; current.append(part); buffer = "" }
                flush()
                var part = segment; part.text = AppleNoteContent.attachment
                result.append(Paragraph(segments: [part], alignment: paragraph.alignment))
            }
            if !buffer.isEmpty { var part = segment; part.text = buffer; current.append(part) }
        }
        flush()
        return result
    }

    var hasChecklist: Bool { paragraphs.contains { if case .check = $0.style { return true }; return false } }
    var hasUnchecked: Bool { paragraphs.contains { $0.style == .check(false) } }
    var hasEmphasis: Bool {
        paragraphs.contains { $0.segments.contains { $0.bold || $0.italic || $0.underline || $0.strikethrough || $0.color != nil || $0.highlight != nil } }
    }

    /// Apple's five highlight colours: purple, pink, orange, mint, blue.
    static func highlight(_ argb: UInt32) -> Int {
        let r = Double((argb >> 16) & 0xff) / 255, g = Double((argb >> 8) & 0xff) / 255, b = Double(argb & 0xff) / 255
        let high = max(r, g, b), low = min(r, g, b)
        guard high - low > 0.05 else { return 3 }
        var hue: Double
        if high == r { hue = 60 * ((g - b) / (high - low)).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = 60 * ((b - r) / (high - low) + 2) }
        else { hue = 60 * ((r - g) / (high - low) + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<20, 330...: return 2
        case ..<75: return 3
        case ..<170: return 4
        case ..<250: return 5
        default: return 1
        }
    }

    func encode(replica: UUID = UUID(), now: Date = Date()) throws -> (data: Data, text: String) {
        let timestamp = Int(now.timeIntervalSince1970)
        var text = ""
        var runs: [Data] = []
        var attachmentIndex = 0
        for (index, paragraph) in paragraphs.enumerated() {
            var segments = paragraph.segments.filter { !$0.text.isEmpty }
            if index < paragraphs.count - 1 {
                if segments.isEmpty { segments = [RichSegment(text: "\n")] } else { segments[segments.count - 1].text += "\n" }
            }
            let paragraphID = uuidData(), checkID = uuidData()
            // Each U+FFFC gets a run of its own so it can carry an attachment.
            var pieces: [(segment: RichSegment, attachment: (identifier: String, uti: String)?)] = []
            for segment in segments {
                var buffer = ""
                for scalar in segment.text.unicodeScalars {
                    guard scalar == "\u{FFFC}" else { buffer.unicodeScalars.append(scalar); continue }
                    if !buffer.isEmpty { var part = segment; part.text = buffer; pieces.append((part, nil)); buffer = "" }
                    var part = segment; part.text = "\u{FFFC}"
                    pieces.append((part, attachmentIndex < attachments.count ? attachments[attachmentIndex] : nil))
                    attachmentIndex += 1
                }
                if !buffer.isEmpty { var part = segment; part.text = buffer; pieces.append((part, nil)) }
            }
            for (segment, attachment) in pieces {
                text += segment.text
                var run = ProtoWriter()
                run.int(1, segment.text.utf16.count)
                run.message(2) { style in
                    switch paragraph.style {
                    case .title: style.int(1, 0)
                    case .body: break
                    case .bullet: style.int(1, 100)
                    case .number: style.int(1, 102)
                    case .check: style.int(1, 103)
                    }
                    // Samsung: 1 right, 2 centre, 3 justified. Apple: 1 centre, 2 right, 3 justified.
                    switch paragraph.alignment { case 1: style.int(2, 2); case 2: style.int(2, 1); case 3: style.int(2, 3); default: break }
                    if paragraph.indent > 0 { style.int(4, paragraph.indent) }
                    if case .check(let done) = paragraph.style { style.message(5) { $0.bytes(1, checkID); $0.int(2, done ? 1 : 0) } }
                    style.bytes(9, paragraphID)
                }
                if let size = segment.size, abs(size - 15) >= 1 { run.message(3) { $0.float(2, Float(size * 13 / 15)) } }
                let weight = (segment.bold ? 1 : 0) | (segment.italic ? 2 : 0)
                if weight != 0 { run.int(5, weight) }
                if segment.underline { run.int(6, 1) }
                if segment.strikethrough { run.int(7, 1) }
                if let color = segment.color {
                    run.message(10) { c in
                        c.float(1, Float((color >> 16) & 0xff) / 255); c.float(2, Float((color >> 8) & 0xff) / 255)
                        c.float(3, Float(color & 0xff) / 255); c.float(4, 1)
                    }
                }
                if let attachment { run.message(12) { $0.string(1, attachment.identifier); $0.string(2, attachment.uti) } }
                run.int(13, timestamp)
                if let highlight = segment.highlight { run.int(14, Self.highlight(highlight)) }
                runs.append(run.data)
            }
        }
        let length = text.utf16.count
        var note = ProtoWriter()
        note.string(2, text)
        // Single-replica topotext: begin sentinel, all text in one substring, end sentinel.
        note.message(3) { s in s.message(1) { $0.int(1, 0); $0.int(2, 0) }; s.int(2, 0); s.message(3) { $0.int(1, 0); $0.int(2, 0) }; s.int(5, 1) }
        note.message(3) { s in s.message(1) { $0.int(1, 1); $0.int(2, 0) }; s.int(2, length); s.message(3) { $0.int(1, 1); $0.int(2, 0) }; s.int(5, 2) }
        note.message(3) { s in s.message(1) { $0.int(1, 0); $0.int(2, 0xFFFF_FFFF) }; s.int(2, 0); s.message(3) { $0.int(1, 0); $0.int(2, 0xFFFF_FFFF) } }
        note.message(4) { clock in
            clock.message(1) { c in c.bytes(1, uuidData(replica)); c.message(2) { $0.int(1, length) }; c.message(2) { $0.int(1, runs.count) } }
        }
        for run in runs { note.bytes(5, run) }
        var document = ProtoWriter()
        document.int(1, 0)
        document.message(2) { d in d.int(1, 0); d.int(2, 0); d.bytes(3, note.data) }
        return (try Gzip.compress(document.data), text)
    }
}

/// A Samsung note rendered for Apple Notes.
struct AppleExport {
    let data: Data
    let content: AppleNoteContent
    let title: String
    let snippet: String
    let titleLine: Bool
    let hasChecklist: Bool, hasUnchecked: Bool, hasEmphasis: Bool
    /// Attachments the note refers to, in text order.
    let attachments: [AppleAttachment]
    /// Drawing paragraphs appended after the body.
    let tail: Int

    static func title(_ value: String) -> String {
        StyledText.normalized(value).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: AppleNoteContent.attachment, with: "").trimmingCharacters(in: .whitespaces)
    }

    static func attachmentCount(_ text: String) -> Int { text.utf16.filter { $0 == 0xFFFC }.count }

    /// `inline` names the attachment for each U+FFFC in the body; `drawings` are appended as their own paragraphs.
    init(title rawTitle: String, body rawBody: String, rich: RichText?, attachments inline: [AppleAttachment?] = [],
         drawings: [AppleAttachment] = [], replica: UUID = UUID()) throws {
        let heading = Self.title(rawTitle)
        let body = StyledText.normalized(rawBody)
        let anchors = Self.attachmentCount(body)
        let slots = Array((inline + Array(repeating: nil, count: max(0, anchors - inline.count))).prefix(anchors)) + drawings.map { Optional($0) }
        attachments = slots.compactMap { $0 }
        tail = drawings.count
        var builder = AppleNoteBuilder()
        builder.attachments = slots.map { $0.map { (identifier: $0.identifier, uti: $0.uti) } }
        titleLine = !heading.isEmpty
        if titleLine { builder.paragraphs.append(.init(segments: [RichSegment(text: heading)], style: .title)) }
        if !body.isEmpty {
            if let rich, rich.text == body {
                for paragraph in rich.previewParagraphs() {
                    let style: AppleNoteBuilder.Style
                    switch paragraph.marker {
                    case .plain: style = .body
                    case .bullet: style = .bullet
                    case .number: style = .number
                    case .checkbox(let done): style = .check(done)
                    }
                    builder.paragraphs.append(.init(segments: paragraph.segments, style: style, alignment: paragraph.alignment, indent: paragraph.indent))
                }
            } else {
                for line in body.components(separatedBy: "\n") { builder.paragraphs.append(.init(segments: [RichSegment(text: line)])) }
            }
        }
        // Attachments on lines of their own, so Notes has nothing to rewrite (1.2.0-beta.5).
        builder.paragraphs = builder.paragraphs.flatMap(AppleNoteBuilder.standalone)
        for _ in drawings { builder.paragraphs.append(.init(segments: [RichSegment(text: AppleNoteContent.attachment)])) }
        if let last = builder.paragraphs.last, AppleNoteContent.attachmentOnly(last.segments.map(\.text).joined()) {
            builder.paragraphs.append(.init(segments: []))
        }
        let encoded = try builder.encode(replica: replica)
        data = encoded.data
        content = try AppleNoteContent.read(encoded.data)
        let visible = body.replacingOccurrences(of: AppleNoteContent.attachment, with: "")
        title = heading.isEmpty ? (visible.split(separator: "\n").first.map(String.init) ?? "Untitled note") : heading
        snippet = String(visible.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init)?.prefix(200) ?? "")
        hasChecklist = builder.hasChecklist; hasUnchecked = builder.hasUnchecked; hasEmphasis = builder.hasEmphasis
    }

    enum DraftResult { case unchanged, draft(NoteDraft), attachmentsChanged }

    /// Turns Apple Notes content back into a Samsung edit: text, title and checklist ticks.
    /// Formatting added in Apple Notes is not carried back. Pictures, tables and drawings
    /// are one-way: when one was added, removed or moved there, the edit is not taken.
    static func samsungDraft(_ content: AppleNoteContent, titleLine: Bool, tail: Int = 0, document: CloudDocument) -> DraftResult {
        var paragraphs = content.text.components(separatedBy: "\n")
        var checks = content.checks
        while checks.count < paragraphs.count { checks.append(nil) }
        checks = Array(checks.prefix(paragraphs.count))
        var newTitle = document.title
        if titleLine, !paragraphs.isEmpty {
            let heading = paragraphs.removeFirst(); checks.removeFirst()
            if heading != title(document.title) { newTitle = heading }
        }
        if tail > 0 {
            // Notes ends a note that finishes with an attachment with a line break.
            if paragraphs.count > tail, paragraphs.last == "", AppleNoteContent.attachmentOnly(paragraphs[paragraphs.count - 2]) {
                paragraphs.removeLast(); checks.removeLast()
            }
            guard paragraphs.count >= tail, paragraphs.suffix(tail).allSatisfy({ $0 == AppleNoteContent.attachment }) else { return .attachmentsChanged }
            paragraphs.removeLast(tail); checks.removeLast(min(tail, checks.count))
        }
        // Attachments sit on lines of their own in Notes; Samsung may have them inside a line.
        let lines = AppleNoteContent.rejoin(zip(paragraphs, checks).map { (text: $0.0, check: $0.1) }, samsung: StyledText.normalized(document.body))
        paragraphs = lines.map(\.text); checks = lines.map(\.check)
        var newBody = paragraphs.joined(separator: "\n")
        if newBody == StyledText.normalized(document.body) { newBody = document.body }
        guard attachmentCount(newBody) == attachmentCount(StyledText.normalized(document.body)) else { return .attachmentsChanged }
        var rich: RichText?
        if let base = document.richBody, !newBody.isEmpty {
            var current = base.withText(StyledText.normalized(newBody))
            // Samsung objects stay anchored only when each U+FFFC keeps its object range.
            guard SamsungAttachments.anchors(current).compactMap({ $0 }) == SamsungAttachments.anchors(base).compactMap({ $0 }) else { return .attachmentsChanged }
            var changed = false
            for (index, have) in current.checkStates.enumerated() where index < checks.count {
                guard let have, let want = checks[index], have != want,
                      let toggled = current.togglingCheckbox(paragraph: index, to: want) else { continue }
                current = toggled; changed = true
            }
            if changed { rich = current }
        }
        if newTitle == document.title && newBody == document.body && rich == nil { return .unchanged }
        return .draft(NoteDraft(title: newTitle, body: newBody, commit: document.commit, richText: rich?.text, richRanges: rich?.ranges))
    }
}

// MARK: - SQLite

enum SQLValue: Equatable {
    case null, int(Int64), real(Double), text(String), blob(Data)
    var int: Int64? { if case .int(let v) = self { return v }; if case .real(let v) = self { return Int64(v) }; return nil }
    var string: String? { if case .text(let v) = self { return v }; return nil }
    var blob: Data? { if case .blob(let v) = self { return v }; return nil }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `readOnly` reads alongside a running Notes (SQLite's write-ahead log gives each read a consistent snapshot).
    init(path: String, readOnly: Bool = false) throws {
        guard sqlite3_open_v2(path, &handle, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle); handle = nil
            throw NotesError.message("Could not open Apple Notes' database (\(message)). Allow Samsung Cloud Notes in System Settings → Privacy & Security → Full Disk Access, then try again.")
        }
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { sqlite3_close(handle) }

    private func error(_ sql: String) -> Error {
        NotesError.message("Apple Notes database error: \(String(cString: sqlite3_errmsg(handle))) [\(sql.prefix(60))]")
    }

    @discardableResult
    func rows(_ sql: String, _ arguments: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error(sql) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
        }
        var result: [[String: SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(sql) }
            var row: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count))
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }

    func insert(_ table: String, _ row: [String: SQLValue]) throws {
        let columns = Array(row.keys)
        let sql = "insert into \(table) (\(columns.map { "\"\($0)\"" }.joined(separator: ","))) values (\(columns.map { _ in "?" }.joined(separator: ",")))"
        try rows(sql, columns.map { row[$0]! })
    }

    func update(_ table: String, pk: Int64, _ values: [String: SQLValue]) throws {
        let columns = Array(values.keys)
        guard !columns.isEmpty else { return }
        let sql = "update \(table) set \(columns.map { "\"\($0)\"=?" }.joined(separator: ",")), Z_OPT=Z_OPT+1 where Z_PK=?"
        try rows(sql, columns.map { values[$0]! } + [.int(pk)])
    }
}

// MARK: - Notes store

final class AppleNoteStore {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite").path
    }
    let db: SQLiteDatabase
    private var entities: [String: Int64] = [:]
    let account: Int64
    /// The account's folder for attachment files (Media, Previews).
    let accountRoot: URL
    /// Files written during the open transaction (removed on rollback) and files to delete once it commits.
    private var written: [URL] = []
    private var removals: [URL] = []
    private var imageTemplate: (attachment: [String: SQLValue], media: [String: SQLValue])?
    private var tableTemplate: [String: SQLValue]?

    struct Found { let pk: Int64; let dataPK: Int64?; let deleted: Bool; let content: AppleNoteContent? }

    init(path: String = AppleNoteStore.defaultPath, readOnly: Bool = false) throws {
        accountRoot = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("Accounts/LocalAccount", isDirectory: true)
        db = try SQLiteDatabase(path: path, readOnly: readOnly)
        for row in try db.rows("select Z_ENT, Z_NAME from Z_PRIMARYKEY") {
            if let name = row["Z_NAME"]?.string, let ent = row["Z_ENT"]?.int { entities[name] = ent }
        }
        guard entities["ICNote"] != nil, entities["ICFolder"] != nil, entities["ICNoteData"] != nil else {
            throw NotesError.message("This Apple Notes database layout is not supported yet.")
        }
        guard let local = try db.rows("select Z_PK from ZICCLOUDSYNCINGOBJECT where ZIDENTIFIER='LocalAccount'").first?["Z_PK"]?.int else {
            throw NotesError.message("Turn on the On My Mac account in Notes → Settings (\"Enable the On My Mac account\"), then try again.")
        }
        account = local
        loadAttachmentTemplates()
    }

    func transaction(_ body: () throws -> Void) throws {
        written = []; removals = []
        try db.rows("begin immediate")
        do { try body(); try db.rows("commit") }
        catch {
            _ = try? db.rows("rollback")
            for url in written { try? FileManager.default.removeItem(at: url) }
            written = []; removals = []
            throw error
        }
        for url in removals { try? FileManager.default.removeItem(at: url) }
        written = []; removals = []
    }

    /// First column named `prefix` or `prefix` + digits holding a value; Core Data adds the digits.
    static func column(_ row: [String: SQLValue], _ prefix: String) -> String? {
        row.keys.filter { key in
            guard key.hasPrefix(prefix) else { return false }
            return key.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }.sorted().first { row[$0] != .null }
    }

    private func object(_ sql: String, _ arguments: [SQLValue]) throws -> [String: SQLValue]? { try db.rows(sql, arguments).first }

    private func nextPK(_ entity: String) throws -> Int64 {
        guard let current = try object("select Z_MAX from Z_PRIMARYKEY where Z_NAME=?", [.text(entity)])?["Z_MAX"]?.int else {
            throw NotesError.message("Apple Notes is missing its \(entity) counter.")
        }
        try db.rows("update Z_PRIMARYKEY set Z_MAX=? where Z_NAME=?", [.int(current + 1), .text(entity)])
        return current + 1
    }

    private func cloneCloudState(_ value: SQLValue?) throws -> SQLValue {
        guard let pk = value?.int, var state = try object("select * from ZICCLOUDSTATE where Z_PK=?", [.int(pk)]) else { return .null }
        let fresh = try nextPK("ICCloudState")
        state["Z_PK"] = .int(fresh); state["Z_OPT"] = .int(1)
        try db.insert("ZICCLOUDSTATE", state)
        return .int(fresh)
    }

    private func isTrash(folder pk: Int64?) throws -> Bool {
        guard let pk, let row = try object("select * from ZICCLOUDSYNCINGOBJECT where Z_PK=?", [.int(pk)]) else { return true }
        return row["ZMARKEDFORDELETION"]?.int == 1 || row["ZFOLDERTYPE"]?.int == 1
    }

    /// The mirror's folder, when it still exists outside the trash.
    func existingFolder(_ identifier: String?) throws -> (pk: Int64, identifier: String)? {
        guard let identifier, let row = try object("select * from ZICCLOUDSYNCINGOBJECT where ZIDENTIFIER=? and Z_ENT=?", [.text(identifier), .int(entities["ICFolder"]!)]),
              let pk = row["Z_PK"]?.int, row["ZMARKEDFORDELETION"]?.int != 1, try !isTrash(folder: pk) else { return nil }
        return (pk, identifier)
    }

    /// The "Samsung Notes" folder in On My Mac, created from the default folder when missing.
    func folder(identifier: String?, name: String) throws -> (pk: Int64, identifier: String) {
        if let existing = try existingFolder(identifier) { return existing }
        guard var template = try object("select * from ZICCLOUDSYNCINGOBJECT where ZIDENTIFIER='DefaultFolder-LocalAccount'", []),
              let titleColumn = Self.column(template, "ZTITLE") else {
            throw NotesError.message("Apple Notes has no On My Mac folder yet. Open Notes, choose On My Mac once, then try again.")
        }
        let pk = try nextPK("ICCloudSyncingObject")
        let identifier = UUID().uuidString
        template["Z_PK"] = .int(pk); template["Z_OPT"] = .int(1)
        template["ZCLOUDSTATE"] = try cloneCloudState(template["ZCLOUDSTATE"])
        template["ZIDENTIFIER"] = .text(identifier)
        template[titleColumn] = .text(name)
        if template["ZSORTORDER"] != nil { template["ZSORTORDER"] = .int(0) }
        try db.insert("ZICCLOUDSYNCINGOBJECT", template)
        return (pk, identifier)
    }

    func find(identifier: String) throws -> Found? {
        guard let row = try object("select * from ZICCLOUDSYNCINGOBJECT where ZIDENTIFIER=? and Z_ENT=?", [.text(identifier), .int(entities["ICNote"]!)]),
              let pk = row["Z_PK"]?.int else { return nil }
        let folder = Self.column(row, "ZFOLDER").flatMap { row[$0]?.int }
        var deleted = row["ZMARKEDFORDELETION"]?.int == 1
        if !deleted { deleted = try isTrash(folder: folder) }
        let dataPK = row["ZNOTEDATA"]?.int
        var content: AppleNoteContent?
        if let dataPK, let blob = try object("select ZDATA from ZICNOTEDATA where Z_PK=?", [.int(dataPK)])?["ZDATA"]?.blob {
            content = try AppleNoteContent.read(blob)
        }
        return Found(pk: pk, dataPK: dataPK, deleted: deleted, content: content)
    }

    private func template() throws -> [String: SQLValue] {
        let notes = try db.rows("select * from ZICCLOUDSYNCINGOBJECT where Z_ENT=? and ZNOTEDATA is not null order by Z_PK desc", [.int(entities["ICNote"]!)])
        let local = notes.filter { row in
            row["ZMARKEDFORDELETION"]?.int != 1 && row["ZISPASSWORDPROTECTED"]?.int != 1 &&
                row.contains { key, value in key.hasPrefix("ZACCOUNT") && key.dropFirst(8).allSatisfy(\.isNumber) && value == .int(account) }
        }
        guard let row = local.first else {
            throw NotesError.message("Create one note in Notes → On My Mac (any text), then sync again. It is used once as a template for Apple's note layout.")
        }
        return row
    }

    private func noteValues(_ row: [String: SQLValue], _ export: AppleExport, modified: Date) -> [String: SQLValue] {
        var values: [String: SQLValue] = [:]
        let stamp = SQLValue.real(modified.timeIntervalSinceReferenceDate)
        if let column = Self.column(row, "ZTITLE") { values[column] = .text(export.title) }
        if let column = Self.column(row, "ZMODIFICATIONDATE") { values[column] = stamp }
        if row["ZSNIPPET"] != nil { values["ZSNIPPET"] = .text(export.snippet) }
        if row["ZWIDGETSNIPPET"] != nil { values["ZWIDGETSNIPPET"] = .text(String(export.content.text.replacingOccurrences(of: AppleNoteContent.attachment, with: "").prefix(1000))) }
        if row["ZHASCHECKLIST"] != nil { values["ZHASCHECKLIST"] = .int(export.hasChecklist ? 1 : 0) }
        if row["ZHASCHECKLISTINPROGRESS"] != nil { values["ZHASCHECKLISTINPROGRESS"] = .int(export.hasUnchecked ? 1 : 0) }
        if row["ZHASEMPHASIS"] != nil { values["ZHASEMPHASIS"] = .int(export.hasEmphasis ? 1 : 0) }
        return values
    }

    /// Inserts a new note; returns its identifier.
    func create(_ export: AppleExport, folder: Int64, modified: Date) throws -> String {
        var row = try template()
        let templateData = row["ZNOTEDATA"]?.int
        let pk = try nextPK("ICCloudSyncingObject"), dataPK = try nextPK("ICNoteData")
        let identifier = UUID().uuidString
        let stamp = SQLValue.real(modified.timeIntervalSinceReferenceDate)
        let accountColumn = row.keys.first { $0.hasPrefix("ZACCOUNT") && $0.dropFirst(8).allSatisfy(\.isNumber) && row[$0] == .int(account) }
        for (key, value) in noteValues(row, export, modified: modified) { row[key] = value }
        row["Z_PK"] = .int(pk); row["Z_OPT"] = .int(1)
        row["ZCLOUDSTATE"] = try cloneCloudState(row["ZCLOUDSTATE"])
        if let accountColumn { row[accountColumn] = .int(account) }
        row[Self.column(row, "ZFOLDER") ?? "ZFOLDER"] = .int(folder)
        row["ZNOTEDATA"] = .int(dataPK)
        row["ZIDENTIFIER"] = .text(identifier)
        if let column = Self.column(row, "ZCREATIONDATE") { row[column] = stamp }
        for key in ["ZFOLDERMODIFICATIONDATE"] where row[key] != nil { row[key] = stamp }
        for key in ["ZLASTOPENEDDATE", "ZLASTVIEWEDMODIFICATIONDATE"] where row[key] != nil { row[key] = .null }
        for key in ["ZISPINNED", "ZMARKEDFORDELETION"] where row[key] != nil { row[key] = .int(0) }
        try db.insert("ZICCLOUDSYNCINGOBJECT", row)
        var data = try templateData.flatMap { try object("select * from ZICNOTEDATA where Z_PK=?", [.int($0)]) }
            ?? ["Z_ENT": .int(entities["ICNoteData"]!)]
        data["Z_PK"] = .int(dataPK); data["Z_OPT"] = .int(1); data["ZNOTE"] = .int(pk); data["ZDATA"] = .blob(export.data)
        try db.insert("ZICNOTEDATA", data)
        try insertAttachments(export.attachments, note: pk, modified: modified)
        return identifier
    }

    func replace(_ found: Found, with export: AppleExport, modified: Date) throws {
        guard let row = try object("select * from ZICCLOUDSYNCINGOBJECT where Z_PK=?", [.int(found.pk)]) else { return }
        try db.update("ZICCLOUDSYNCINGOBJECT", pk: found.pk, noteValues(row, export, modified: modified))
        if let dataPK = found.dataPK { try db.update("ZICNOTEDATA", pk: dataPK, ["ZDATA": .blob(export.data)]) }
        try removeAttachments(note: found.pk)
        try insertAttachments(export.attachments, note: found.pk, modified: modified)
    }

    // MARK: Attachments

    private func isLocal(_ row: [String: SQLValue]) -> Bool {
        row.contains { key, value in key.hasPrefix("ZACCOUNT") && key.dropFirst(8).allSatisfy(\.isNumber) && value == .int(account) }
    }

    /// Apple's own picture and table rows in On My Mac, used as the layout for new ones.
    private func loadAttachmentTemplates() {
        guard let attachment = entities["ICAttachment"], entities["ICMedia"] != nil,
              let rows = try? db.rows("select * from ZICCLOUDSYNCINGOBJECT where Z_ENT=? and ZMARKEDFORDELETION=0 order by Z_PK desc", [.int(attachment)]) else { return }
        let local = rows.filter(isLocal)
        tableTemplate = local.first { $0["ZTYPEUTI"]?.string == "com.apple.notes.table" && $0["ZISPASSWORDPROTECTED"]?.int != 1 }
        for row in local where row["ZISPASSWORDPROTECTED"]?.int != 1 {
            guard let uti = row["ZTYPEUTI"]?.string, uti.hasPrefix("public.") || uti == "com.compuserve.gif",
                  UTType(uti)?.conforms(to: .image) == true, let mediaPK = row["ZMEDIA"]?.int,
                  let media = try? object("select * from ZICCLOUDSYNCINGOBJECT where Z_PK=?", [.int(mediaPK)]),
                  media["ZMARKEDFORDELETION"]?.int != 1, Self.column(media, "ZFILENAME") != nil else { continue }
            imageTemplate = (row, media); break
        }
    }

    /// Whether this store has the layout needed to write `attachment` (Apple's own picture or table in On My Mac).
    func supports(_ attachment: AppleAttachment) -> Bool {
        attachment.isTable ? (tableTemplate ?? imageTemplate?.attachment) != nil : imageTemplate != nil
    }

    private func cleared(_ template: [String: SQLValue], note: Int64, identifier: String, modified: Date) throws -> [String: SQLValue] {
        var row = template
        let stamp = SQLValue.real(modified.timeIntervalSinceReferenceDate)
        row["Z_PK"] = .int(try nextPK("ICCloudSyncingObject")); row["Z_OPT"] = .int(1)
        row["ZCLOUDSTATE"] = try cloneCloudState(row["ZCLOUDSTATE"])
        row["ZIDENTIFIER"] = .text(identifier)
        row[Self.column(row, "ZNOTE") ?? "ZNOTE"] = .int(note)
        for key in ["ZCREATIONDATE", "ZMODIFICATIONDATE"] where row[key] != nil { row[key] = stamp }
        // Apple fills these in itself (text recognition, image classification, previews).
        for key in ["ZTITLE", "ZUSERTITLE", "ZSUMMARY", "ZOCRSUMMARY", "ZIMAGECLASSIFICATIONSUMMARY", "ZHANDWRITINGSUMMARY", "ZFALLBACKTITLE",
                    "ZADDITIONALINDEXABLETEXT", "ZPREVIEWUPDATEDATE", "ZURLSTRING", "ZSERVERRECORDDATA", "ZSERVERSHAREDATA", "ZMEDIA"] where row[key] != nil {
            row[key] = .null
        }
        for key in ["ZOCRSUMMARYVERSION", "ZIMAGECLASSIFICATIONSUMMARYVERSION", "ZHANDWRITINGSUMMARYVERSION", "ZCHECKEDFORLOCATION",
                    "ZDIDRUNPAPERFORMDETECTION", "ZHASMARKUPDATA", "ZORIENTATION", "ZIMAGEFILTERTYPE", "ZISPASSWORDPROTECTED"] where row[key] != nil {
            row[key] = .int(0)
        }
        for key in row.keys where key.hasPrefix("ZMERGEABLEDATA") { row[key] = .null }
        return row
    }

    /// The column Notes reads a table from: ZMERGEABLEDATA1 (ZMERGEABLEDATA, without the number, is
    /// ignored for tables; up to 1.2.0-beta.3 it was written there). Older stores: the column Apple's own table uses.
    static func tableDataColumn(template: [String: SQLValue]?, row: [String: SQLValue]) -> String {
        if row["ZMERGEABLEDATA1"] != nil { return "ZMERGEABLEDATA1" }
        if let used = template?.keys.sorted().first(where: { $0.hasPrefix("ZMERGEABLEDATA") && template?[$0]?.blob != nil }) { return used }
        return row.keys.sorted().first { $0.hasPrefix("ZMERGEABLEDATA") && $0.count > 14 && $0.dropFirst(14).allSatisfy(\.isNumber) } ?? "ZMERGEABLEDATA1"
    }

    private func insertAttachments(_ attachments: [AppleAttachment], note: Int64, modified: Date) throws {
        for attachment in attachments {
            switch attachment.kind {
            case .table(let cells):
                guard let template = tableTemplate ?? imageTemplate?.attachment else { continue }
                var row = try cleared(template, note: note, identifier: attachment.identifier, modified: modified)
                let table = try AppleTable.data(cells)
                row["ZTYPEUTI"] = .text(attachment.uti)
                row[Self.tableDataColumn(template: tableTemplate, row: row)] = .blob(table.data)
                row["ZSUMMARY"] = .text(table.summary)
                for key in ["ZSIZEWIDTH", "ZSIZEHEIGHT"] where row[key] != nil { row[key] = .real(0) }
                if row["ZFILESIZE"] != nil { row["ZFILESIZE"] = .int(0) }
                if tableTemplate == nil, row["ZMINIMUMSUPPORTEDNOTESVERSION"] != nil { row["ZMINIMUMSUPPORTEDNOTESVERSION"] = .int(2) }
                try db.insert("ZICCLOUDSYNCINGOBJECT", row)
            case .image(let data, let uti, let fileName, let width, let height):
                guard let template = imageTemplate else { continue }
                var row = try cleared(template.attachment, note: note, identifier: attachment.identifier, modified: modified)
                guard let attachmentPK = row["Z_PK"]?.int else { continue }
                var media = template.media
                let mediaPK = try nextPK("ICCloudSyncingObject")
                let mediaID = UUID().uuidString, generation = "1_" + UUID().uuidString
                media["Z_PK"] = .int(mediaPK); media["Z_OPT"] = .int(1)
                media["ZCLOUDSTATE"] = try cloneCloudState(media["ZCLOUDSTATE"])
                media["ZIDENTIFIER"] = .text(mediaID)
                media[Self.column(media, "ZFILENAME") ?? "ZFILENAME"] = .text(fileName)
                media[Self.column(media, "ZGENERATION") ?? "ZGENERATION1"] = .text(generation)
                media[Self.column(media, "ZATTACHMENT") ?? "ZATTACHMENT1"] = .int(attachmentPK)
                for key in ["ZSERVERRECORDDATA", "ZSERVERSHAREDATA"] where media[key] != nil { media[key] = .null }
                row["ZMEDIA"] = .int(mediaPK)
                row["ZTYPEUTI"] = .text(uti)
                if row["ZSIZEWIDTH"] != nil { row["ZSIZEWIDTH"] = .real(width) }
                if row["ZSIZEHEIGHT"] != nil { row["ZSIZEHEIGHT"] = .real(height) }
                if row["ZFILESIZE"] != nil { row["ZFILESIZE"] = .int(Int64(data.count)) }
                let folder = accountRoot.appendingPathComponent("Media/\(mediaID)", isDirectory: true)
                let file = folder.appendingPathComponent(generation, isDirectory: true).appendingPathComponent(fileName)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                written.append(folder)
                try data.write(to: file, options: .atomic)
                try db.insert("ZICCLOUDSYNCINGOBJECT", row)
                try db.insert("ZICCLOUDSYNCINGOBJECT", media)
            }
        }
    }

    private func delete(_ row: [String: SQLValue]) throws {
        guard let pk = row["Z_PK"]?.int else { return }
        if let state = row["ZCLOUDSTATE"]?.int { try db.rows("delete from ZICCLOUDSTATE where Z_PK=?", [.int(state)]) }
        try db.rows("delete from ZICCLOUDSYNCINGOBJECT where Z_PK=?", [.int(pk)])
    }

    /// Deletes a mirrored note's attachments (rows now, files once the transaction commits).
    private func removeAttachments(note: Int64) throws {
        guard let attachment = entities["ICAttachment"] else { return }
        let previews = entities["ICAttachmentPreviewImage"]
        for row in try db.rows("select * from ZICCLOUDSYNCINGOBJECT where Z_ENT=? and ZNOTE=?", [.int(attachment), .int(note)]) {
            guard let pk = row["Z_PK"]?.int else { continue }
            if let mediaPK = row["ZMEDIA"]?.int, let media = try object("select * from ZICCLOUDSYNCINGOBJECT where Z_PK=?", [.int(mediaPK)]) {
                if let id = media["ZIDENTIFIER"]?.string, !id.isEmpty { removals.append(accountRoot.appendingPathComponent("Media/\(id)", isDirectory: true)) }
                try delete(media)
            }
            if let previews {
                for preview in (try? db.rows("select * from ZICCLOUDSYNCINGOBJECT where Z_ENT=? and ZATTACHMENT=?", [.int(previews), .int(pk)])) ?? [] { try delete(preview) }
            }
            if let id = row["ZIDENTIFIER"]?.string, !id.isEmpty {
                for folder in ["Previews", "FallbackImages", "FallbackPDFs"] {
                    let directory = accountRoot.appendingPathComponent(folder, isDirectory: true)
                    for item in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where item.hasPrefix(id) {
                        removals.append(directory.appendingPathComponent(item))
                    }
                }
            }
            try delete(row)
        }
    }
}

// MARK: - Mirror state and sync

/// Which Apple note mirrors which Samsung note, and what each side looked like at the last sync.
struct AppleMirror: Codable {
    struct Entry: Codable {
        var identifier: String; var commit: String; var fingerprint: String; var titleLine: Bool
        /// Drawing paragraphs after the body, and attachments written (nil before 1.2.0-beta.3).
        var tail: Int? = nil
        var attachments: Int? = nil
        /// Export format the Apple copy was written with; older copies are rewritten when unchanged in Apple Notes.
        var format: Int? = nil
        /// What the Apple copy said at the last sync (text and checklist states), so edits made
        /// on both sides can be merged (nil before 1.2.0-beta.4).
        var baseText: String? = nil
        var baseChecks: String? = nil
        /// An Apple edit was handed to the app as a draft: the Apple copy is the base from then on, so
        /// whatever is saved to Samsung afterwards (that draft, or later edits undoing it) wins (1.2.0-beta.5).
        var imported: Bool? = nil
        var base: AppleNoteContent? {
            get { baseText.map { AppleNoteContent(text: $0, checkString: baseChecks ?? "") } }
            set { baseText = newValue?.text; baseChecks = newValue?.checkString }
        }
    }
    /// 2: tables are written where Notes reads them (1.2.0-beta.4).
    /// 3: attachments on lines of their own, as Notes keeps them (1.2.0-beta.5).
    static let format = 3
    var folder: String?
    var notes: [String: Entry] = [:]

    static func url() throws -> URL { try LocalStore.directory("AppleNotes").appendingPathComponent("mirror.json") }
    static func load(_ url: URL) -> AppleMirror {
        guard let data = try? Data(contentsOf: url) else { return AppleMirror() }
        return (try? JSONDecoder().decode(AppleMirror.self, from: data)) ?? AppleMirror()
    }
    func save(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor enum AppleNotesSync {
    struct Report {
        var created = 0, updated = 0, unchanged = 0, removed = 0
        var attachments = 0, unavailable = 0
        var imported: [String] = []
        var conflicts: [String] = []
        var attachmentEdits: [String] = []
        /// Changed on both sides in the same place: the Apple version was kept as its own note.
        var kept: [String] = []
        var merged = 0
        /// Read-only passes: Apple notes that need writing (created, replaced or kept), left for a write pass.
        var pendingWrites = 0
        var summary: String {
            var parts = ["Apple Notes: \(created) added", "\(updated) updated", "\(imported.count) changes brought back as drafts"]
            if merged > 0 { parts.append("\(merged) edited on both sides and merged") }
            if !kept.isEmpty { parts.append("\(kept.count) edited on both sides in the same place (your Apple Notes version was kept as a separate note)") }
            if attachments > 0 { parts.append("\(attachments) pictures, tables and drawings written") }
            if unavailable > 0 { parts.append("\(unavailable) pictures or tables not available yet (connect to Samsung Cloud, then sync again)") }
            if !conflicts.isEmpty { parts.append("\(conflicts.count) skipped (an unsaved draft here, or the note can't be edited)") }
            if !attachmentEdits.isEmpty { parts.append("\(attachmentEdits.count) with pictures or tables changed in Apple Notes (not brought back)") }
            if removed > 0 { parts.append("\(removed) removed in Apple Notes (left alone)") }
            return parts.joined(separator: " · ")
        }
    }

    static func quitNotes() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")
        running.forEach { $0.terminate() }
        for _ in 0..<60 {
            if running.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NotesError.message("Apple Notes did not quit. Quit it yourself, then sync again.")
    }

    static var notesRunning: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes") }

    /// `activate: false` brings Notes back behind the current app, without taking focus.
    static func openNotes(activate: Bool = true) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// After writing: open Notes as the sync button does, only if it was running (in front again only
    /// if it was in front), or not at all (a note is being typed in this app).
    enum Reopen { case always, ifRunning, never }

    private(set) static var inProgress = false

    /// Pictures resolved per note revision, so frequent read-only passes do not reread them.
    private static var resolvedMemo: [String: (commit: String, value: (inline: [AppleAttachment?], drawings: [AppleAttachment]))] = [:]

    /// Copies Apple's store before writing; keeps the five newest copies.
    static func backup(_ path: String) throws {
        let root = try LocalStore.directory("AppleNotesBackups")
        let target = root.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: target.appendingPathComponent("NoteStore.sqlite" + suffix).path)
        }
        let all = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
    }

    /// Mirrors `items` into Apple Notes and turns edits made there into local drafts.
    /// `writes: false` only reads Notes' database (Notes keeps running): edits made there still become
    /// drafts, and notes that need writing are counted in `pendingWrites`.
    static func run(_ items: [(record: NoteRecord, document: CloudDocument)], drafts: NoteDraftStore,
                    path: String = AppleNoteStore.defaultPath, mirrorURL: URL? = nil, manageNotesApp: Bool = true,
                    writes: Bool = true, reopen: Reopen = .always, backup makeBackup: Bool = true,
                    load: (AssetRecord, CloudDocument) async -> Data? = { _, _ in nil }) async throws -> Report {
        let mirrorURL = try mirrorURL ?? AppleMirror.url()
        guard FileManager.default.fileExists(atPath: path) else {
            throw NotesError.message("Apple Notes has no data on this Mac yet. Open Notes once, then try again.")
        }
        // One pass at a time: the button and automatic sync share the mirror and Notes' database.
        guard !inProgress else { throw NotesError.message("Apple Notes is being synced automatically right now. Try again in a moment.") }
        inProgress = true; defer { inProgress = false }
        var report = Report()
        // Pictures are fetched before Notes is closed, so it stays usable during downloads.
        var resolved: [String: (inline: [AppleAttachment?], drawings: [AppleAttachment])] = [:]
        for (_, document) in items {
            let found: (inline: [AppleAttachment?], drawings: [AppleAttachment])
            if let memo = resolvedMemo[document.serverID], memo.commit == document.commit { found = memo.value }
            else {
                found = await SamsungAttachments.resolve(document) { await load($0, document) }
                if !found.inline.contains(where: { $0 == nil }) { resolvedMemo[document.serverID] = (document.commit, found) }
            }
            resolved[document.serverID] = found
            report.unavailable += found.inline.filter { $0 == nil }.count
        }
        let manage = manageNotesApp && writes
        let running = manage ? notesRunning : []
        let wasInFront = running.contains { $0.isActive }
        if manage && !running.isEmpty { try await quitNotes() }
        defer {
            if manage {
                switch reopen {
                case .always: openNotes()
                case .ifRunning: if !running.isEmpty { openNotes(activate: wasInFront) }
                case .never: break
                }
            }
        }
        if manage && makeBackup { try backup(path) }
        let store = try AppleNoteStore(path: path, readOnly: !writes)
        var mirror = AppleMirror.load(mirrorURL)
        /// Read-only passes leave notes that need writing for later.
        func deferred() -> Bool {
            if writes { return false }
            report.pendingWrites += 1
            return true
        }
        func pass() throws {
            let folder: (pk: Int64, identifier: String)
            if writes { folder = try store.folder(identifier: mirror.folder, name: "Samsung Notes") }
            else if let existing = try store.existingFolder(mirror.folder) { folder = existing }
            else { report.pendingWrites = items.count; return }
            mirror.folder = folder.identifier
            for (record, document) in items {
                let id = document.serverID
                let modified = Date(timeIntervalSince1970: record.modified / 1000)
                let objects = resolved[id] ?? ([], [])
                report.unavailable += (objects.inline.compactMap { $0 } + objects.drawings).filter { !store.supports($0) }.count
                let export = try AppleExport(title: document.title, body: document.body, rich: document.richBody,
                                             attachments: objects.inline.map { $0.flatMap { store.supports($0) ? $0 : nil } },
                                             drawings: objects.drawings.filter(store.supports))
                func written(_ entry: inout AppleMirror.Entry) {
                    entry.commit = document.commit; entry.fingerprint = export.content.fingerprint; entry.titleLine = export.titleLine
                    entry.tail = export.tail; entry.attachments = export.attachments.count; entry.format = AppleMirror.format
                    entry.base = export.content; entry.imported = nil
                    report.attachments += export.attachments.count
                }
                /// Brings an Apple edit back as a local draft (saved to Samsung from the app). From then on the
                /// Apple copy counts as seen: the next Samsung revision replaces it, even one that undoes the edit.
                func importDraft(_ draft: NoteDraft, apple: AppleNoteContent, entry: inout AppleMirror.Entry) throws -> Bool {
                    if document.editIssue != nil || document.resource.attr("isLocked") == "true" { report.conflicts.append(id); return false }
                    // A newer Apple edit replaces the draft the last one became, unless that draft was changed
                    // here or merged with Samsung edits (it then no longer matches what the Apple copy said).
                    var previous: NoteDraft?
                    if entry.imported == true, let base = entry.base,
                       case .draft(let earlier) = AppleExport.samsungDraft(base, titleLine: entry.titleLine, tail: entry.tail ?? 0, document: document) { previous = earlier }
                    if let existing = try drafts.read(id), existing != draft, existing != previous { report.conflicts.append(id); return false }
                    try drafts.write(draft, id: id)
                    report.imported.append(id)
                    entry.commit = document.commit; entry.fingerprint = apple.fingerprint; entry.base = apple; entry.imported = true
                    mirror.notes[id] = entry
                    return true
                }
                guard var entry = mirror.notes[id] else {
                    if deferred() { continue }
                    var entry = AppleMirror.Entry(identifier: try store.create(export, folder: folder.pk, modified: modified), commit: "", fingerprint: "", titleLine: false)
                    written(&entry)
                    mirror.notes[id] = entry; report.created += 1
                    continue
                }
                guard let found = try store.find(identifier: entry.identifier), !found.deleted, let apple = found.content else {
                    report.removed += 1; continue
                }
                // Notes moves attachments onto lines of their own when it opens a note; that alone is no edit.
                let appleChanged = apple.fingerprint != entry.fingerprint && (entry.base.map { $0.standalone != apple.standalone } ?? true)
                let samsungChanged = document.commit != entry.commit
                // Pictures that could not be fetched last time are added once they can.
                let missingAttachments = export.attachments.count > (entry.attachments ?? 0)
                let outdated = (entry.format ?? 0) < AppleMirror.format
                // While an Apple edit waits in the app as a draft, its Apple copy is left as it is; once the
                // draft is discarded there, the Apple copy goes back to Samsung's version.
                let waiting = entry.imported == true ? try drafts.read(id) != nil : false
                let discarded = entry.imported == true && !waiting
                let same = apple.standalone == export.content
                // A saved Apple edit also leaves no draft behind; it needs no rewrite when both sides already match.
                if !appleChanged && ((samsungChanged && !same) || (!waiting && (missingAttachments || outdated || (discarded && !same)))) {
                    if deferred() { continue }
                    try store.replace(found, with: export, modified: modified)
                    written(&entry)
                    mirror.notes[id] = entry; report.updated += 1
                } else if !appleChanged || same {
                    // Nothing to carry either way (a saved draft lands here): the Apple copy stays as it is.
                    entry.commit = document.commit; entry.fingerprint = apple.fingerprint; entry.base = apple
                    if same { entry.imported = nil }
                    mirror.notes[id] = entry; report.unchanged += 1
                } else if !samsungChanged {
                    switch AppleExport.samsungDraft(apple, titleLine: entry.titleLine, tail: entry.tail ?? 0, document: document) {
                    case .unchanged:
                        entry.fingerprint = apple.fingerprint; entry.base = apple; mirror.notes[id] = entry; report.unchanged += 1
                    case .attachmentsChanged:
                        report.attachmentEdits.append(id)
                    case .draft(let draft):
                        _ = try importDraft(draft, apple: apple, entry: &entry)
                    }
                } else if let base = entry.base, entry.titleLine == export.titleLine, (entry.tail ?? 0) == export.tail,
                          let merged = AppleNoteContent.merge(base: base.standalone, apple: apple.standalone, samsung: export.content) {
                    // Edited on both sides in different places.
                    let result: AppleExport.DraftResult = merged == export.content ? .unchanged
                        : AppleExport.samsungDraft(merged, titleLine: export.titleLine, tail: export.tail, document: document)
                    switch result {
                    case .unchanged:
                        // Samsung's version already holds the Apple edits.
                        if deferred() { continue }
                        try store.replace(found, with: export, modified: modified)
                        written(&entry)
                        mirror.notes[id] = entry; report.updated += 1; report.merged += 1
                    case .attachmentsChanged:
                        report.attachmentEdits.append(id)
                    case .draft(let draft):
                        // Saved from the app, the merged note then replaces the Apple copy on the next sync.
                        if try importDraft(draft, apple: apple, entry: &entry) { report.merged += 1 }
                    }
                } else {
                    // Same place edited on both sides (or synced before 1.2.0-beta.4, with no record to merge
                    // against): the Apple version stays as it is, unlinked, next to a fresh copy of the Samsung note.
                    if deferred() { continue }
                    var fresh = AppleMirror.Entry(identifier: try store.create(export, folder: folder.pk, modified: modified), commit: "", fingerprint: "", titleLine: false)
                    written(&fresh)
                    mirror.notes[id] = fresh; report.kept.append(id)
                }
            }
        }
        if writes { try store.transaction(pass) } else { try pass() }
        try mirror.save(mirrorURL)
        return report
    }
}

extension NotesModel {
    /// The notes mirrored into Apple Notes: everything downloaded that is not trashed or locked.
    var appleSyncItems: [(record: NoteRecord, document: CloudDocument)] {
        notes.filter { !$0.trashed && !$0.locked && !$0.encrypted }
            .compactMap { record in loaded[record.id].map { (record: record, document: $0) } }
    }
    func syncAppleNotes() async {
        guard !busy else { return }
        preserveDraft()
        busy = true; status = "Syncing with Apple Notes…"
        defer { busy = false }
        do {
            let report = try await AppleNotesSync.run(appleSyncItems, drafts: drafts) { asset, document in
                try? await self.attachmentData(asset, document: document)
            }
            if let id = selection, report.imported.contains(id), let document = loaded[id] { try present(document) }
            status = report.summary
        } catch {
            self.error = "Apple Notes sync did not finish: " + error.localizedDescription
            status = "Apple Notes sync stopped; its database was rolled back. Backups: Local copies → AppleNotesBackups."
        }
    }
}

/// Offline checks: build a note, read it back, and map an Apple edit to a Samsung draft.
enum AppleNotesSelfTest {
    static func run() throws {
        let rich = try RichText.parse(RichTextSelfTest.encoded, orderData: RichTextSelfTest.order)
        let export = try AppleExport(title: "Shopping", body: rich.text, rich: rich)
        guard export.content.text == "Shopping\n" + rich.text, export.content.checks == [nil, nil, false, nil, nil],
              export.titleLine, export.hasChecklist, export.hasUnchecked else {
            throw NotesError.message("Apple Notes export mismatch: \(export.content)")
        }
        let raw = try Gzip.decompress(export.data)
        guard try Gzip.decompress(Gzip.compress(raw)) == raw, Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926 else {
            throw NotesError.message("Gzip round trip failed.")
        }
        guard AppleNoteBuilder.highlight(0xFFFF_EB3B) == 3, AppleNoteBuilder.highlight(0xFF21_96F3) == 5 else {
            throw NotesError.message("Highlight mapping mismatch.")
        }
        try attachments()
    }
}

extension AppleNotesSelfTest {
    static func document(_ commit: String, body: RichText, objects: String = "", id: String = "scnselftest") throws -> CloudDocument {
        let xml = "<CompareNoteView><commitId>\(commit)</commitId><noteResource id=\"selftest\">\(objects)<attributes><title><object><text>\(StyledText.encodeTitle("Shopping"))</text></object></title></attributes><bodyText><object><text>\(body.encode())</text></object></bodyText></noteResource></CompareNoteView>"
        return try CloudDocument(serverID: id, data: Data(xml.utf8))
    }

    /// Automatic sync on a copy of a real NoteStore.sqlite: read-only passes (Notes keeps running) bring Apple
    /// edits in, never write Apple's database, and leave Samsung changes for a write pass.
    static func live(_ path: String) async throws -> String {
        guard path != AppleNoteStore.defaultPath else { throw NotesError.message("Run the live test on a copy of the Notes store.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scn-apple-live-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirrorURL = dir.appendingPathComponent("mirror.json"), drafts = NoteDraftStore(root: dir)
        let rich = try RichText.parse(RichTextSelfTest.encoded, orderData: RichTextSelfTest.order)
        let doc = try document("l1", body: rich, id: "scnlivetest"), id = doc.serverID
        let record = NoteRecord(id: id, resourceID: "", commit: "l1", modified: Date().timeIntervalSince1970 * 1000, locked: false, encrypted: false)
        func sync(_ d: CloudDocument, writes: Bool) async throws -> AppleNotesSync.Report {
            try await AppleNotesSync.run([(record: record, document: d)], drafts: drafts, path: path, mirrorURL: mirrorURL, manageNotesApp: false, writes: writes)
        }
        var report = try await sync(doc, writes: false)
        guard report.pendingWrites == 1, report.created == 0, AppleMirror.load(mirrorURL).notes.isEmpty else {
            throw NotesError.message("A read-only pass wrote a new note: \(report.summary)")
        }
        report = try await sync(doc, writes: true)
        guard report.created == 1, let identifier = AppleMirror.load(mirrorURL).notes[id]?.identifier else { throw NotesError.message("Live test note was not created.") }
        let store = try AppleNoteStore(path: path)
        func appleEdit(_ body: String) throws {
            guard let note = try store.find(identifier: identifier) else { throw NotesError.message("Live test note vanished.") }
            try store.transaction { try store.replace(note, with: AppleExport(title: "Shopping", body: body, rich: rich.withText(body)), modified: Date()) }
        }
        let first = rich.text + "\nTyped in Notes", second = first + ", still typing"
        try appleEdit(first)
        report = try await sync(doc, writes: false)
        guard report.imported == [id], try drafts.read(id)?.body == first else { throw NotesError.message("A live Apple edit was not read: \(report.summary)") }
        try appleEdit(second)
        report = try await sync(doc, writes: false)
        guard report.imported == [id], report.conflicts.isEmpty, try drafts.read(id)?.body == second else {
            throw NotesError.message("A newer Apple edit did not replace the earlier one's draft: \(report.summary)")
        }
        // A draft changed here is never replaced; the Apple edit waits as a conflict.
        try drafts.write(NoteDraft(title: doc.title, body: second + " and here", commit: doc.commit), id: id)
        try appleEdit(second + ", more")
        report = try await sync(doc, writes: false)
        guard report.conflicts == [id], try drafts.read(id)?.body == second + " and here" else {
            throw NotesError.message("An Apple edit replaced text typed here: \(report.summary)")
        }
        // Saved to Samsung as Notes shows it: nothing to write, so Notes would keep running.
        try appleEdit(second); try drafts.discard(id)
        report = try await sync(try document("l2", body: rich.withText(second), id: id), writes: false)
        guard report.pendingWrites == 0, report.unchanged == 1 else { throw NotesError.message("A saved Apple edit asked for a rewrite: \(report.summary)") }
        // A Samsung change waits for a write pass, then lands.
        let phone = try document("l3", body: rich.withText(second + "\nFrom the phone"), id: id)
        let before = try store.find(identifier: identifier)?.content
        report = try await sync(phone, writes: false)
        guard report.pendingWrites == 1, try store.find(identifier: identifier)?.content == before else {
            throw NotesError.message("A read-only pass changed Apple Notes: \(report.summary)")
        }
        report = try await sync(phone, writes: true)
        guard report.updated == 1, try store.find(identifier: identifier)?.content?.text.hasSuffix("From the phone") == true else {
            throw NotesError.message("The Samsung change was not written: \(report.summary)")
        }
        return "Apple Notes live test passed: read-only pass writes nothing, live Apple edit → draft, newer edit replaces it, text typed here kept, saved edit → no rewrite, Samsung change → pending → written."
    }

    /// The self-test note plus a picture and a 2×2 table anchored on U+FFFC, as Samsung writes them
    /// (`inline`: the picture inside a line of text, as Samsung allows and Notes does not).
    static func withObjects(_ rich: RichText, inline: Bool = false) -> (rich: RichText, xml: String) {
        let text = rich.text + (inline ? "\u{FFFC}after picture\n\u{FFFC}" : "\n\u{FFFC}\n\u{FFFC}")
        let base = rich.withText(text)
        let units = Array(text.utf16)
        let anchors = units.indices.filter { units[$0] == 0xFFFC }
        let ranges = base.ranges + [
            StyleRange(key: SamsungAttachments.objectSpan, value: "obj-img,0,0", start: anchors[0], end: anchors[0] + 1, sequence: 9000),
            StyleRange(key: SamsungAttachments.objectSpan, value: "obj-tab,3,2", start: anchors[1], end: anchors[1] + 1, sequence: 9001),
        ]
        let table = samsungTable([(33, 41, "Item"), (361, 41, "Qty"), (33, 97.5, "Milk"), (361, 97.5, "2")]).base64EncodedString()
        let xml = "<contentFileList><contentFile id=\"imgasset\" name=\"\(Data("0@photo.png".utf8).base64EncodedString())\"/></contentFileList>"
            + "<floatingObjectList><object id=\"obj-img\" type=\"image\"><fillEffect imageId=\"imgasset\"/></object>"
            + "<object id=\"obj-tab\" type=\"tableNew\"><tableBinary>\(table)</tableBinary></object></floatingObjectList>"
        return (RichText(text: text, ranges: ranges), xml)
    }

    /// End-to-end check against a copy of a real NoteStore.sqlite (never the live one).
    static func database(_ path: String) async throws -> String {
        guard path != AppleNoteStore.defaultPath else { throw NotesError.message("Run the database test on a copy of the Notes store.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scn-apple-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirrorURL = dir.appendingPathComponent("mirror.json")
        let drafts = NoteDraftStore(root: dir)
        let plain = try RichText.parse(RichTextSelfTest.encoded, orderData: RichTextSelfTest.order)
        let (rich, objects) = withObjects(plain)
        let doc = try document("c1", body: rich, objects: objects)
        guard let parsed = doc.richBody, SamsungAttachments.anchors(parsed) == ["obj-img", "obj-tab"] else {
            throw NotesError.message("Test document did not parse its objects.")
        }
        let record = NoteRecord(id: doc.serverID, resourceID: "", commit: "c1", modified: Date().timeIntervalSince1970 * 1000, locked: false, encrypted: false)
        let picture = testImage()
        func sync(_ d: CloudDocument) async throws -> AppleNotesSync.Report {
            try await AppleNotesSync.run([(record: record, document: d)], drafts: drafts, path: path, mirrorURL: mirrorURL, manageNotesApp: false) { asset, _ in
                asset.id == "imgasset" ? picture : nil
            }
        }
        let store = try AppleNoteStore(path: path)
        let media = store.accountRoot.appendingPathComponent("Media", isDirectory: true)
        let mediaBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? [])
        func attachments(_ identifier: String) throws -> [String] {
            guard let pk = try store.find(identifier: identifier)?.pk else { return [] }
            return try store.db.rows("select ZTYPEUTI from ZICCLOUDSYNCINGOBJECT where ZNOTE=? and ZTYPEUTI is not null order by ZTYPEUTI", [.int(pk)]).compactMap { $0["ZTYPEUTI"]?.string }
        }
        func pictureFiles() throws -> Int {
            let added = Set((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []).subtracting(mediaBefore)
            for folder in added {
                let rows = try store.db.rows("select ZFILENAME, ZGENERATION1 from ZICCLOUDSYNCINGOBJECT where ZIDENTIFIER=?", [.text(folder)])
                guard let row = rows.first, let name = row["ZFILENAME"]?.string, let generation = row["ZGENERATION1"]?.string,
                      (try? Data(contentsOf: media.appendingPathComponent("\(folder)/\(generation)/\(name)"))) == picture else {
                    throw NotesError.message("Picture file \(folder) does not match its media row.")
                }
            }
            return added.count
        }

        var report = try await sync(doc)
        guard report.created == 1, report.attachments == 2, report.unavailable == 0 else { throw NotesError.message("Create failed: \(report.summary)") }
        let entry = AppleMirror.load(mirrorURL).notes[doc.serverID]!
        guard try attachments(entry.identifier) == ["com.apple.notes.table", "public.png"], try pictureFiles() == 1 else {
            throw NotesError.message("Attachments were not written: \(try attachments(entry.identifier))")
        }
        report = try await sync(doc)
        guard report.unchanged == 1, report.created == 0 else { throw NotesError.message("Second sync was not a no-op: \(report.summary)") }

        // Edit in "Apple Notes": change a word and tick the checklist item.
        guard let found = try store.find(identifier: entry.identifier), !found.deleted, let appleText = found.content?.text,
              appleText == "Shopping\n" + rich.text + "\n" else {
            throw NotesError.message("Created note did not read back identically.")
        }
        let editedText = rich.text.replacingOccurrences(of: "Bold word", with: "Bold words")
        let editedRich = rich.withText(editedText).togglingCheckbox(paragraph: 1)!
        try store.transaction { try store.replace(found, with: AppleExport(title: "Shopping", body: editedText, rich: editedRich), modified: Date()) }
        guard try attachments(entry.identifier).isEmpty, try pictureFiles() == 0 else { throw NotesError.message("Old attachments were not removed.") }
        report = try await sync(doc)
        guard report.imported == [doc.serverID], let draft = try drafts.read(doc.serverID), draft.body == editedText,
              draft.title == doc.title, draft.rich?.withText(editedText).checkStates == [nil, true, nil, nil, nil, nil],
              SamsungAttachments.anchors(draft.rich ?? parsed.withText(draft.body)) == ["obj-img", "obj-tab"] else {
            throw NotesError.message("Apple edit was not brought back with its pictures anchored: \(report.summary)")
        }
        // Once saved to Samsung (new revision with the same content), the mirror settles without rewriting.
        let saved = try document("c2", body: editedRich, objects: objects)
        report = try await sync(saved)
        guard report.unchanged == 1, report.updated == 0, report.conflicts.isEmpty else { throw NotesError.message("Saved edit did not settle: \(report.summary)") }
        // A Samsung-side change rewrites the Apple note, attachments included.
        let newer = try document("c3", body: rich.withText(editedText + "\nAdded on phone"), objects: objects)
        report = try await sync(newer)
        guard report.updated == 1, try store.find(identifier: entry.identifier)?.content?.text.hasSuffix("Added on phone") == true,
              try attachments(entry.identifier).count == 2, try pictureFiles() == 1 else {
            throw NotesError.message("Samsung change was not mirrored: \(report.summary)")
        }
        // Tables go where Notes reads them.
        guard let notePK = try store.find(identifier: entry.identifier)?.pk,
              let tableRow = try store.db.rows("select * from ZICCLOUDSYNCINGOBJECT where ZNOTE=? and ZTYPEUTI='com.apple.notes.table'", [.int(notePK)]).first,
              tableRow["ZMERGEABLEDATA1"]?.blob != nil, tableRow["ZMERGEABLEDATA"]?.blob == nil else {
            throw NotesError.message("The table was not written to ZMERGEABLEDATA1.")
        }

        // An Apple edit handed over as a draft, saved, then undone on the phone: the phone's version wins.
        func appleEdit(_ body: String) throws {
            guard let note = try store.find(identifier: entry.identifier) else { throw NotesError.message("Mirrored note vanished.") }
            try store.transaction { try store.replace(note, with: AppleExport(title: "Shopping", body: body, rich: rich.withText(body)), modified: Date()) }
        }
        try drafts.discard(doc.serverID) // the earlier draft, saved above (the app removes it on save)
        try appleEdit(newer.body + "\nFrom the Mac")
        report = try await sync(newer)
        guard report.imported == [doc.serverID], try drafts.read(doc.serverID)?.body == newer.body + "\nFrom the Mac" else {
            throw NotesError.message("An Apple edit was not handed over: \(report.summary)")
        }
        let undone = try document("c3a", body: rich.withText(newer.body), objects: objects)
        report = try await sync(undone)
        guard report.updated == 1, report.imported.isEmpty,
              try store.find(identifier: entry.identifier)?.content?.text.contains("From the Mac") == false else {
            throw NotesError.message("A phone edit undoing a handed-over Apple edit was overwritten: \(report.summary)")
        }
        // Handed over, then discarded in the app: the Apple copy goes back to Samsung's version.
        try drafts.discard(doc.serverID)
        try appleEdit(newer.body + "\nFrom the Mac")
        report = try await sync(undone)
        guard report.imported == [doc.serverID] else { throw NotesError.message("A second Apple edit was not handed over: \(report.summary)") }
        try drafts.discard(doc.serverID)
        report = try await sync(undone)
        guard report.updated == 1, try store.find(identifier: entry.identifier)?.content?.text.contains("From the Mac") == false else {
            throw NotesError.message("A discarded Apple edit stayed in Apple Notes: \(report.summary)")
        }

        // Ticked in Apple Notes while a line was added on the phone: both edits are kept.
        try drafts.discard(doc.serverID)
        guard let mirrored = try store.find(identifier: entry.identifier) else { throw NotesError.message("Mirrored note vanished.") }
        let newerRich = rich.withText(newer.body)
        try store.transaction { try store.replace(mirrored, with: AppleExport(title: "Shopping", body: newer.body, rich: newerRich.togglingCheckbox(paragraph: 1)), modified: Date()) }
        let phone = try document("c4", body: rich.withText(newer.body + "\nSecond phone line"), objects: objects)
        report = try await sync(phone)
        guard report.merged == 1, report.imported == [doc.serverID], let mergedDraft = try drafts.read(doc.serverID),
              mergedDraft.body == phone.body, let mergedRich = mergedDraft.rich, mergedRich.withText(mergedDraft.body).checkStates.dropFirst().first == true else {
            throw NotesError.message("Edits on both sides were not merged into a draft: \(report.summary)")
        }
        // Saved to Samsung, the merged note replaces the Apple copy.
        let merged = try document("c5", body: mergedRich.withText(mergedDraft.body), objects: objects)
        try drafts.discard(doc.serverID)
        report = try await sync(merged)
        guard report.updated == 1, let after = try store.find(identifier: entry.identifier)?.content,
              after.text.hasSuffix("Second phone line"), after.checks.dropFirst(2).first == true else {
            throw NotesError.message("The saved merge did not reach Apple Notes: \(report.summary)")
        }

        // The same line changed differently on both sides: the Apple version is kept as its own note.
        guard let beforeConflict = try store.find(identifier: entry.identifier) else { throw NotesError.message("Mirrored note vanished.") }
        let appleWording = merged.body.replacingOccurrences(of: "Second phone line", with: "Second Mac line")
        try store.transaction { try store.replace(beforeConflict, with: AppleExport(title: "Shopping", body: appleWording, rich: mergedRich.withText(appleWording)), modified: Date()) }
        let clash = try document("c6", body: mergedRich.withText(merged.body.replacingOccurrences(of: "Second phone line", with: "Second phone line, edited")), objects: objects)
        report = try await sync(clash)
        let fresh = AppleMirror.load(mirrorURL).notes[doc.serverID]!
        guard report.kept == [doc.serverID], fresh.identifier != entry.identifier,
              try store.find(identifier: entry.identifier)?.content?.text.hasSuffix("Second Mac line") == true,
              try store.find(identifier: fresh.identifier)?.content?.text.hasSuffix("Second phone line, edited") == true else {
            throw NotesError.message("A clash did not keep both versions: \(report.summary)")
        }
        report = try await sync(clash)
        guard report.unchanged == 1, report.kept.isEmpty else { throw NotesError.message("Kept copy did not settle: \(report.summary)") }

        // A picture deleted in Apple Notes is not taken back to Samsung.
        guard let current = try store.find(identifier: fresh.identifier) else { throw NotesError.message("Mirrored note vanished.") }
        let withoutPicture = clash.body.replacingOccurrences(of: "\n\u{FFFC}\n", with: "\n")
        try store.transaction { try store.replace(current, with: AppleExport(title: "Shopping", body: withoutPicture, rich: nil), modified: Date()) }
        report = try await sync(clash)
        guard report.attachmentEdits == [doc.serverID], report.imported.isEmpty else {
            throw NotesError.message("Removing a picture in Apple Notes was not held back: \(report.summary)")
        }
        return "Apple Notes database test passed: create with picture + table (in ZMERGEABLEDATA1), no-op resync, Apple edit + tick → draft (pictures kept), settle after save, Samsung change → update, handed-over edit undone on the phone → phone wins, discarded draft → Apple reverted, edits on both sides → merged draft → Apple updated, clash → Apple version kept, picture removed in Apple → held back."
    }
}

extension AppleNotesSelfTest {
    /// Syncs every cached Samsung note into a copy of the Notes store twice: the first
    /// pass must create them all, the second must change nothing. No session needed.
    static func cached(_ path: String) async throws -> String {
        guard path != AppleNoteStore.defaultPath else { throw NotesError.message("Run the cache test on a copy of the Notes store.") }
        let (items, load) = try cachedNotes()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scn-apple-cache-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("mirror.json"), drafts = NoteDraftStore(root: dir)
        let first = try await AppleNotesSync.run(items, drafts: drafts, path: path, mirrorURL: mirror, manageNotesApp: false, load: load)
        let second = try await AppleNotesSync.run(items, drafts: drafts, path: path, mirrorURL: mirror, manageNotesApp: false, load: load)
        guard first.created == items.count, second.unchanged == items.count else {
            throw NotesError.message("Cached-note sync was not stable. First: \(first.summary). Second: \(second.summary)")
        }
        let formatted = items.filter { $0.document.richBody?.hasVisibleFormatting == true }.count
        let checklists = items.filter { $0.document.richBody?.checkStates.contains { $0 != nil } == true }.count
        return "Cached-note test passed: \(items.count) notes (\(formatted) formatted, \(checklists) with checklists) created with \(first.attachments) pictures, tables and drawings (\(first.unavailable) not cached), then a resync changed nothing."
    }

    /// The real sync, from the app's local copies only: no sign-in or network needed.
    static func syncFromCache() async throws -> String {
        let (items, load) = try cachedNotes()
        return try await AppleNotesSync.run(items, drafts: NoteDraftStore(), load: load).summary
    }

    /// Every cached Samsung note (newest copy of each) and a loader for its cached pictures.
    static func cachedNotes() throws -> (items: [(record: NoteRecord, document: CloudDocument)], load: (AssetRecord, CloudDocument) async -> Data?) {
        func key(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        struct Entry: Codable { var revision: String; var xml: Data }
        var items: [(record: NoteRecord, document: CloudDocument)] = []
        var folders: [String: URL] = [:]
        let cache = LocalStore.root.appendingPathComponent("Cache")
        for folder in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
                  let snapshot = try? JSONDecoder().decode(NoteCache.Snapshot.self, from: data) else { continue }
            for record in snapshot.index.notes where !record.trashed && !record.locked && !record.encrypted {
                guard let raw = try? Data(contentsOf: folder.appendingPathComponent("note-" + key(record.id))),
                      let entry = try? JSONDecoder().decode(Entry.self, from: raw), entry.revision == record.commit,
                      let document = try? CloudDocument(serverID: record.id, data: entry.xml) else { continue }
                items.append((record, document))
                folders[record.id] = folder
            }
        }
        // Several sign-ins can cache the same note; keep the newest copy of each.
        var newest: [String: (record: NoteRecord, document: CloudDocument)] = [:]
        for item in items where (newest[item.record.id]?.record.modified ?? -1) < item.record.modified { newest[item.record.id] = item }
        items = Array(newest.values)
        guard !items.isEmpty else { throw NotesError.message("No cached Samsung notes found.") }
        // Pictures come from the app's attachment cache only (no network).
        let roots = Array(Set(folders.values))
        let load: (AssetRecord, CloudDocument) async -> Data? = { asset, document in
            roots.lazy.compactMap { try? Data(contentsOf: $0.appendingPathComponent("asset-" + key(asset.id + ":" + document.commit))) }.first
        }
        return (items.sorted { $0.record.modified < $1.record.modified }, load)
    }
}
