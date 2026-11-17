import SwiftUI

/// Read-only rendering of Samsung rich text: character styles, colours,
/// highlights, sizes, alignment, indentation, bullets, numbers and checklists.
/// Interpretation is best effort; the saved markup never depends on it.

struct RichSegment: Equatable {
    var text: String
    var bold = false, italic = false, underline = false, strikethrough = false
    /// Samsung point size; the default body size is 15.
    var size: Double?
    var color: UInt32?
    var highlight: UInt32?
}

enum RichMarker: Equatable { case plain, bullet, number(Int), checkbox(checked: Bool) }

struct RichParagraph: Equatable {
    var segments: [RichSegment] = []
    /// 0 left, 1 right, 2 centre, 3 justified.
    var alignment = 0
    var indent = 0
    var marker = RichMarker.plain
}

extension RichText {
    /// Whether a formatted view shows anything a plain editor would not.
    var hasVisibleFormatting: Bool { !hasOnlyDefaultStyling }

    func previewParagraphs() -> [RichParagraph] {
        let units = Array(text.utf16)
        let newline = UInt16(ascii: "\n")
        let starts = [0] + units.indices.filter { $0 > 0 && units[$0] == newline }
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
                case "indentLevel": paragraph.indent = parts.first.flatMap { Int($0) } ?? 0
                case _ where range.name == "bullet" || descriptor.contains("checker") || descriptor.contains("digit") || descriptor.contains("solidcircle"):
                    if descriptor.contains("checker") { paragraph.marker = .checkbox(checked: parts.contains("true")) }
                    else if descriptor.contains("digit") { paragraph.marker = .number(0) }
                    else { paragraph.marker = .bullet }
                default: break
                }
            }
            if case .number = paragraph.marker {
                let next = (numbering[paragraph.indent] ?? 0) + 1
                numbering = numbering.filter { $0.key < paragraph.indent }
                numbering[paragraph.indent] = next
                paragraph.marker = .number(next)
            } else if paragraph.marker == .plain { numbering = [:] }
            var boundaries = Set([contentStart, end])
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
        case "hyperText": underline = true
        default: break
        }
    }
}

struct RichTextPreview: View {
    let paragraphs: [RichParagraph]
    let baseSize: CGFloat

    init(rich: RichText, baseSize: CGFloat) {
        paragraphs = rich.previewParagraphs()
        self.baseSize = baseSize
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in row(paragraph) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func row(_ paragraph: RichParagraph) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch paragraph.marker {
            case .plain: EmptyView()
            case .bullet: Text("•")
            case .number(let value): Text("\(value).").monospacedDigit()
            case .checkbox(let checked): Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
            }
            Text(attributed(paragraph))
                .multilineTextAlignment(paragraph.alignment == 2 ? .center : paragraph.alignment == 1 ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: paragraph.alignment == 2 ? .center : paragraph.alignment == 1 ? .trailing : .leading)
        }
        .font(.system(size: baseSize))
        .padding(.leading, CGFloat(paragraph.indent) * 20)
    }

    private func attributed(_ paragraph: RichParagraph) -> AttributedString {
        var checked = false
        if case .checkbox(checked: true) = paragraph.marker { checked = true }
        var result = AttributedString()
        // An empty paragraph still needs a line's height.
        for segment in paragraph.segments.isEmpty ? [RichSegment(text: " ")] : paragraph.segments {
            var piece = AttributedString(segment.text)
            var font = Font.system(size: segment.size.map { CGFloat($0) * baseSize / 15 } ?? baseSize)
            if segment.bold { font = font.bold() }
            if segment.italic { font = font.italic() }
            piece.font = font
            if let color = segment.color { piece.foregroundColor = Self.color(color) }
            if let highlight = segment.highlight { piece.backgroundColor = Self.color(highlight) }
            if segment.underline { piece.underlineStyle = Text.LineStyle.single }
            // Samsung strikes through and greys out completed checklist items.
            if segment.strikethrough || checked { piece.strikethroughStyle = Text.LineStyle.single }
            if checked { piece.foregroundColor = Color.secondary }
            result += piece
        }
        return result
    }

    private static func color(_ argb: UInt32) -> Color {
        Color(.sRGB, red: Double((argb >> 16) & 0xff) / 255, green: Double((argb >> 8) & 0xff) / 255,
              blue: Double(argb & 0xff) / 255, opacity: Double(argb >> 24) / 255)
    }
}

/// Offline checks for the preview model.
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
    }
}
