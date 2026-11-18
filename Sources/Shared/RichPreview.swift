import Foundation

/// Display model of Samsung rich text: character styles, colours, highlights,
/// sizes, alignment, indentation, bullets, numbers and checklists.
/// Interpretation is best effort; the saved markup never depends on it.

struct RichSegment: Equatable {
    var text: String
    var bold = false, italic = false, underline = false, strikethrough = false
    /// Samsung point size; the default body size is 15.
    var size: Double?
    var color: UInt32?
    var highlight: UInt32?
    var link = false
}

enum RichMarker: Equatable { case plain, bullet, number(Int), checkbox(checked: Bool) }

struct RichParagraph: Equatable {
    var segments: [RichSegment] = []
    /// 0 left, 1 right, 2 centre, 3 justified.
    var alignment = 0
    var indent = 0
    var marker = RichMarker.plain
    var checked: Bool { if case .checkbox(true) = marker { return true }; return false }
}

extension RichText {
    /// Whether a formatted view shows anything a plain editor would not.
    var hasVisibleFormatting: Bool { !hasOnlyDefaultStyling }

    /// UTF-16 offset of each paragraph's first unit; paragraph k > 0 starts at its leading line break.
    var paragraphStarts: [Int] {
        let units = Array(text.utf16)
        let newline = UInt16(UInt8(ascii: "\n"))
        return [0] + units.indices.filter { $0 > 0 && units[$0] == newline }
    }

    /// Samsung bullet values are `type,state`: 2 is a checklist item (state true/false),
    /// 4–7 and 9 are numbered styles, other types draw a bullet. Older payloads use names.
    static func marker(forBullet value: String) -> RichMarker? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.lowercased() }
        guard let kind = parts.first else { return nil }
        let done = parts.count > 1 && ["true", "1"].contains(parts.last!)
        switch kind {
        case "checker", "2": return .checkbox(checked: done)
        case "", "0", "none": return nil
        case "digit", "4", "5", "6", "7", "9": return .number(0)
        default: return .bullet
        }
    }

    func previewParagraphs() -> [RichParagraph] {
        let units = Array(text.utf16)
        let starts = paragraphStarts
        let spans = ranges.filter { $0.isSpan && !$0.isEmpty }
        var result: [RichParagraph] = []
        var numbering: [Int: Int] = [:]
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : units.count
            let contentStart = index == 0 ? start : min(start + 1, end)
            var paragraph = RichParagraph()
            for range in ranges where range.isParagraph && !range.isEmpty && range.start <= start && start < range.end {
                let parts = range.value.split(separator: ",", omittingEmptySubsequences: false).map { $0.lowercased() }
                let descriptor = ([range.name.lowercased()] + parts).joined(separator: ",")
                switch range.name {
                case "alignment": paragraph.alignment = Int(range.value) ?? Int(range.flag) ?? 0
                case "indentLevel": paragraph.indent = max(0, min(8, Int(range.flag) ?? 0))
                case "bullet": if let marker = Self.marker(forBullet: range.value) { paragraph.marker = marker }
                case _ where descriptor.contains("checker"): paragraph.marker = .checkbox(checked: parts.contains("true"))
                case _ where descriptor.contains("digit"): paragraph.marker = .number(0)
                case _ where descriptor.contains("solidcircle"): paragraph.marker = .bullet
                default: break
                }
            }
            if case .number = paragraph.marker {
                let next = (numbering[paragraph.indent] ?? 0) + 1
                numbering = numbering.filter { $0.key < paragraph.indent }
                numbering[paragraph.indent] = next
                paragraph.marker = .number(next)
            } else if paragraph.marker == .plain { numbering = [:] }
            var boundaries: Set<Int> = [contentStart, end]
            for span in spans where span.start < end && span.end > contentStart {
                boundaries.insert(max(span.start, contentStart)); boundaries.insert(min(span.end, end))
            }
            let cuts = boundaries.sorted()
            for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                var segment = RichSegment(text: String(decoding: units[a..<b], as: UTF16.self))
                for span in spans where span.start <= a && a < span.end { segment.apply(span) }
                paragraph.segments.append(segment)
            }
            result.append(paragraph)
        }
        return result
    }

    /// Checklist state per paragraph (nil for other paragraphs).
    var checkStates: [Bool?] {
        previewParagraphs().map { if case .checkbox(let done) = $0.marker { return done }; return nil }
    }

    /// The same text with one checklist item ticked or unticked. Only that paragraph
    /// changes, even when its style range covers several paragraphs.
    func togglingCheckbox(paragraph: Int, to newValue: Bool? = nil) -> RichText? {
        let starts = paragraphStarts
        guard paragraph >= 0, paragraph < starts.count else { return nil }
        let start = starts[paragraph]
        let end = paragraph + 1 < starts.count ? starts[paragraph + 1] : text.utf16.count
        guard let index = ranges.lastIndex(where: { r in
            r.isParagraph && !r.isEmpty && r.start <= start && start < r.end &&
                (r.name == "bullet" ? Self.marker(forBullet: r.value).map { if case .checkbox = $0 { return true }; return false } ?? false
                                    : r.value.lowercased().contains("checker"))
        }) else { return nil }
        let range = ranges[index]
        var parts = range.value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let current = parts.count > 1 && ["true", "1"].contains(parts.last!.lowercased())
        let target = newValue ?? !current
        if target == current { return self }
        if parts.count > 1, let last = parts.last {
            switch last {
            case "true", "false": parts[parts.count - 1] = target ? "true" : "false"
            case "True", "False": parts[parts.count - 1] = target ? "True" : "False"
            case "TRUE", "FALSE": parts[parts.count - 1] = target ? "TRUE" : "FALSE"
            default: parts[parts.count - 1] = target ? "1" : "0"
            }
        } else { parts.append(target ? "true" : "false") }
        var pieces: [StyleRange] = []
        if range.start < start { var before = range; before.end = start; pieces.append(before) }
        var toggled = range; toggled.start = start; toggled.end = min(end, range.end); toggled.value = parts.joined(separator: ",")
        pieces.append(toggled)
        if end < range.end { var after = range; after.start = end; pieces.append(after) }
        var updated = ranges
        updated.replaceSubrange(index...index, with: pieces)
        return RichText(text: text, ranges: updated)
    }
}

extension RichSegment {
    /// Samsung's default near-black body colour; left to the system so dark mode stays readable.
    static let defaultColor: UInt32 = 0xFF25_2525

    mutating func apply(_ span: StyleRange) {
        let on = ["true", "1"].contains(span.flag.lowercased())
        let argb = Int(span.flag).map { UInt32(bitPattern: Int32(truncatingIfNeeded: $0)) }
        switch span.name {
        case "bold": bold = on
        case "italic": italic = on
        case "underline": underline = on
        case "strikethrough": strikethrough = on
        case "fontSize": size = Double(span.flag)
        case "foregroundColor": color = argb.flatMap { $0 >> 24 == 0 || $0 == Self.defaultColor ? nil : $0 }
        case "backgroundColor": highlight = argb.flatMap { $0 >> 24 == 0 ? nil : $0 }
        case "hyperText": underline = true; link = true
        default: break
        }
    }
}

/// Offline checks for the display model.
enum RichPreviewSelfTest {
    static func run() throws {
        let rich = try RichText.parse(RichTextSelfTest.encoded, orderData: RichTextSelfTest.order)
        let paragraphs = rich.previewParagraphs()
        guard rich.hasVisibleFormatting, paragraphs.count == 4,
              paragraphs[0].segments.map(\.text).joined() == "Title line", paragraphs[0].marker == .plain,
              paragraphs[1].marker == .checkbox(checked: false), paragraphs[1].segments.map(\.text).joined() == "Check",
              paragraphs[2].segments.first?.text == "Bold", paragraphs[2].segments.first?.bold == true,
              paragraphs[2].segments.last?.text == " word", paragraphs[2].segments.last?.color == 0xFFFF_0000,
              paragraphs[2].segments.last?.bold == false, paragraphs[3].segments.first?.color == nil else {
            throw NotesError.message("Rich text preview model mismatch.")
        }
        guard try !RichText.parse(StyledText.encode("plain\ntext")).hasVisibleFormatting else {
            throw NotesError.message("Plain text was reported as formatted.")
        }
        // Ticking a checklist item changes only its state, and survives re-encoding.
        guard let ticked = rich.togglingCheckbox(paragraph: 1), ticked.checkStates == [nil, true, nil, nil],
              let reparsed = try? RichText.parse(ticked.encode(), orderData: ticked.spanOrderData()),
              reparsed.checkStates == [nil, true, nil, nil], reparsed.text == rich.text,
              rich.togglingCheckbox(paragraph: 2) == nil,
              ticked.togglingCheckbox(paragraph: 1)?.checkStates == [nil, false, nil, nil] else {
            throw NotesError.message("Checklist toggle mismatch.")
        }
        // Real Samsung bullet values.
        guard RichText.marker(forBullet: "2,true") == .checkbox(checked: true), RichText.marker(forBullet: "2,false") == .checkbox(checked: false),
              RichText.marker(forBullet: "4,1") == .number(0), RichText.marker(forBullet: "8,0") == .bullet else {
            throw NotesError.message("Bullet type mapping mismatch.")
        }
    }
}
