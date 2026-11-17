import Foundation

// Samsung stores typed text as Base64 UTF-8 runs separated by `<?a …?>` markers.
// Inside a marker, `'key'='value'` opens an attribute at the current UTF-16
// offset and a bare `'key'` closes the most recent open attribute with that key.
// Spans (`span/bold`, `span/foregroundColor`, …) style character ranges;
// paragraph attributes (`paragraph/alignment`, bullets, checkboxes, …) style
// whole paragraphs; `sectionData` records the section length.
//
// Every attribute is kept as an opaque range, so formatting this client cannot
// display still survives an edit: ranges are remapped through a diff of the old
// and new text and written back with a matching spanOrderDataList.
//
// The Android port (android/app/.../RichText.kt) mirrors this file; keep them in step.

struct StyleRange: Equatable {
    var key: String
    var value: String
    var start: Int
    var end: Int
    /// Position of the opening token in the original stream.
    var sequence: Int
    /// Index of the matching spanOrderData record; unmatched spans sort last.
    var orderRank = Int.max
    /// Samsung span type identifier taken from spanOrderData, when known.
    var typeID: Int? = nil

    var isSpan: Bool { key.hasPrefix("span/") }
    var isParagraph: Bool { key.hasPrefix("paragraph/") }
    var isEmpty: Bool { start == end }
    var name: String {
        guard let slash = key.firstIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }
    /// The last comma-separated component, e.g. `True` in `1,True`.
    var flag: String { value.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? value }
}

struct RichText {
    let text: String
    let ranges: [StyleRange]

    static let unsupported = "This note uses formatting markup this version cannot rewrite safely. It is read-only here so the formatting is not lost."
    /// Samsung's span identifiers (spanOrderData and the sdocx rich-text model).
    static let spanTypes: [String: Int] = [
        "foregroundColor": 1, "fontSize": 3, "fontName": 4, "bold": 5, "italic": 6,
        "underline": 7, "hyperText": 9, "backgroundColor": 17, "strikethrough": 20,
    ]
    private static let marker = try! NSRegularExpression(pattern: "<\\?(.*?)\\?>", options: [.dotMatchesLineSeparators])
    private static let token = try! NSRegularExpression(pattern: "'([^']*)'(?:='([^']*)')?")
    private static let newline = UInt16(UInt8(ascii: "\n"))

    static func parse(_ encoded: String, orderData: [String] = []) throws -> RichText {
        if encoded.isEmpty { return RichText(text: "", ranges: []) }
        guard let data = Data(base64Encoded: encoded.filter { !$0.isWhitespace }),
              let source = String(data: data, encoding: .utf8) else {
            throw NotesError.message("This text uses an unsupported encoding. Its original data has been retained.")
        }
        func blank(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ns = source as NSString
        var text: [UInt16] = []
        var keys: [String] = [], values: [String] = [], starts: [Int] = [], ends: [Int] = []
        var open: [String: [Int]] = [:]
        var offset = 0
        for match in marker.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            text += try decodeRun(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            offset = match.range.location + match.range.length
            let body = ns.substring(with: match.range(at: 1))
            guard body == "a" || body.hasPrefix("a ") else { throw NotesError.message(unsupported) }
            let content = String(body.dropFirst()) as NSString
            var position = 0
            for item in token.matches(in: content as String, range: NSRange(location: 0, length: content.length)) {
                guard blank(content.substring(with: NSRange(location: position, length: item.range.location - position))) else { throw NotesError.message(unsupported) }
                position = item.range.location + item.range.length
                let key = content.substring(with: item.range(at: 1))
                let valueRange = item.range(at: 2)
                if valueRange.location != NSNotFound {
                    keys.append(key); values.append(content.substring(with: valueRange)); starts.append(text.count); ends.append(-1)
                    open[key, default: []].append(keys.count - 1)
                } else {
                    guard let index = open[key]?.popLast() else { throw NotesError.message(unsupported) }
                    ends[index] = text.count
                }
            }
            guard blank(content.substring(from: position)) else { throw NotesError.message(unsupported) }
        }
        text += try decodeRun(ns.substring(from: offset))
        let parsed = keys.indices.map { i in
            StyleRange(key: keys[i], value: values[i], start: starts[i], end: ends[i] < 0 ? text.count : ends[i], sequence: i)
        }
        return RichText(text: String(decoding: text, as: UTF16.self), ranges: matchOrderData(parsed, orderData))
    }

    private static func decodeRun(_ value: String) throws -> [UInt16] {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let data = Data(base64Encoded: value.filter { !$0.isWhitespace }), let text = String(data: data, encoding: .utf8) else {
            throw NotesError.message("This text includes an unsupported span. Export the original document to retain it.")
        }
        return Array(text.utf16)
    }

    /// Attaches each spanOrderData record (`type,start,end,value`) to the span it describes.
    private static func matchOrderData(_ ranges: [StyleRange], _ orderData: [String]) -> [StyleRange] {
        var result = ranges
        var used = [Bool](repeating: false, count: result.count)
        for (rank, encoded) in orderData.enumerated() {
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else { continue }
            let record = decoded.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard record.count == 4, let type = Int(record[0]), let start = Int(record[1]), let end = Int(record[2]) else { continue }
            guard let index = result.indices.first(where: { i in
                let range = result[i]
                return !used[i] && range.isSpan && range.start == start && range.end == end && range.value == record[3] &&
                    (spanTypes[range.name] ?? type) == type
            }) else { continue }
            used[index] = true
            result[index].orderRank = rank
            result[index].typeID = type
        }
        return result
    }

    /// True when nothing visible would be lost by rewriting the text with the plain
    /// 1.1 encoder: whole-text size/colour defaults, "off" styles, left alignment
    /// and bookkeeping only. Older clients produced such markup.
    var hasOnlyDefaultStyling: Bool {
        let length = text.utf16.count
        return ranges.allSatisfy { range in
            if range.isEmpty { return true }
            switch range.key {
            case "paragraph/parsingState", "sectionData/sectionData": return true
            case "paragraph/alignment": return range.value == "0"
            case "span/fontSize", "span/foregroundColor": return range.start == 0 && range.end == length
            case "span/backgroundColor": return range.flag == "0"
            case "span/bold", "span/italic", "span/underline", "span/strikethrough": return range.flag.lowercased() == "false"
            default: return false
            }
        }
    }

    /// Returns the same formatting carried over to `newText` (UTF-16 offsets, `\n` line breaks).
    func withText(_ newText: String) -> RichText {
        if newText == text { return self }
        let old = Array(text.utf16), new = Array(newText.utf16)
        let origin = TextDiff.origins(old, new)
        func map(_ position: Int) -> Int {
            var low = 0, high = origin.count
            while low < high { let mid = (low + high) / 2; if origin[mid] < position { low = mid + 1 } else { high = mid } }
            return low
        }
        // Paragraph k starts at 0 or at its leading line break, as Samsung writes it.
        let paragraphStarts = [0] + new.indices.filter { $0 > 0 && new[$0] == Self.newline }
        var result: [StyleRange] = []
        for range in ranges {
            if range.isEmpty {
                let position = Self.keepSurrogates(new, map(range.start), forward: true)
                var moved = range; moved.start = position; moved.end = position
                result.append(moved)
                continue
            }
            let start = Self.keepSurrogates(new, map(range.start), forward: false)
            let end = Self.keepSurrogates(new, map(range.end), forward: true)
            if end <= start { continue }
            var moved = range
            if range.key == "sectionData/sectionData" && range.value == String(range.end - range.start) { moved.value = String(end - start) }
            moved.start = start; moved.end = end
            if !range.isParagraph { result.append(moved); continue }
            // A one-paragraph style applies to each paragraph typed inside it (a new
            // checklist line); every paragraph style covers whole paragraphs only, and
            // a merged paragraph keeps the style of the paragraph it starts with.
            let single = !old[(range.start + 1)..<range.end].contains(Self.newline)
            let pieces = single ? Self.splitParagraphs(new, moved) : [moved]
            result += pieces.compactMap { Self.snapToParagraphs($0, paragraphStarts, new.count) }
        }
        return RichText(text: newText, ranges: result)
    }

    /// Normalises legacy values that native Samsung parsers rejected in 1.1.0 uploads.
    func normalizedForUpload() -> RichText {
        RichText(text: text, ranges: ranges.compactMap { range in
            if range.isSpan && range.isEmpty { return nil } // caret-only typing styles
            var copy = range
            switch range.key {
            case "paragraph/parsingState": copy.value = range.value.lowercased()
            case "span/fontSize":
                let parts = range.value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2, Int(parts[1]) != nil { copy.value = parts[0] + "," + parts[1] + ".0" }
            default: break
            }
            return copy
        })
    }

    /// Base64 `<text>` payload.
    func encode() -> String {
        if text.isEmpty && ranges.isEmpty { return "" }
        let units = Array(text.utf16)
        let positions = Set(ranges.flatMap { [$0.start, $0.end] } + [0, units.count]).sorted()
        var active: [StyleRange] = []
        var payload = ""
        for (index, position) in positions.enumerated() {
            let closing = active.filter { $0.end == position }
            active.removeAll { $0.end == position }
            let closeTokens = closing.reversed().map { "'\($0.key)'" }
            var openTokens: [String] = []
            // Zero-length entries first, as Samsung writes them, so FIFO and LIFO readers agree.
            let starting = ranges.filter { $0.start == position }.sorted { a, b in
                if a.isEmpty != b.isEmpty { return a.isEmpty }
                if a.end != b.end { return a.end > b.end }
                return a.sequence < b.sequence
            }
            for range in starting {
                openTokens.append("'\(range.key)'='\(range.value)'")
                if range.end == position { openTokens.append("'\(range.key)'") } else { active.append(range) }
            }
            if position == units.count && !closeTokens.isEmpty && !openTokens.isEmpty {
                payload += "<?a " + closeTokens.joined(separator: " ") + "?>"
                payload += "<?a " + openTokens.joined(separator: " ") + "?>"
            } else if !closeTokens.isEmpty || !openTokens.isEmpty {
                payload += "<?a " + (closeTokens + openTokens).joined(separator: " ") + "?>"
            }
            guard index + 1 < positions.count else { break }
            let next = positions[index + 1]
            if next > position { payload += Data(String(decoding: units[position..<next], as: UTF16.self).utf8).base64EncodedString() }
        }
        return Data(payload.utf8).base64EncodedString()
    }

    /// Base64 spanOrderData values, in Samsung's original span order.
    func spanOrderData() throws -> [String] {
        try ranges.filter { $0.isSpan && !$0.isEmpty }
            .sorted { $0.orderRank != $1.orderRank ? $0.orderRank < $1.orderRank : $0.sequence < $1.sequence }
            .map { range in
                guard let type = range.typeID ?? Self.spanTypes[range.name] else {
                    throw NotesError.message("This note uses a text style (\(range.name)) this version cannot save yet. Its formatting has been kept unchanged.")
                }
                return Data("\(type),\(range.start),\(range.end),\(range.value)".utf8).base64EncodedString()
            }
    }

    private static func splitParagraphs(_ units: [UInt16], _ range: StyleRange) -> [StyleRange] {
        var pieces: [StyleRange] = []
        var start = range.start
        for index in (range.start + 1)..<range.end where units[index] == newline {
            var piece = range; piece.start = start; piece.end = index
            pieces.append(piece); start = index
        }
        var last = range; last.start = start
        pieces.append(last)
        return pieces
    }

    /// Expands a range to the paragraphs whose first unit it covers; nil if it covers none.
    private static func snapToParagraphs(_ range: StyleRange, _ starts: [Int], _ length: Int) -> StyleRange? {
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] < range.start { low = mid + 1 } else { high = mid } }
        let first = low
        guard first < starts.count, starts[first] < range.end else { return nil }
        var last = first
        while last + 1 < starts.count && starts[last + 1] < range.end { last += 1 }
        var snapped = range
        snapped.start = starts[first]
        snapped.end = last + 1 < starts.count ? starts[last + 1] : length
        return snapped
    }

    private static func keepSurrogates(_ units: [UInt16], _ position: Int, forward: Bool) -> Int {
        guard position > 0, position < units.count, UTF16.isLeadSurrogate(units[position - 1]), UTF16.isTrailSurrogate(units[position]) else { return position }
        return forward ? position + 1 : position - 1
    }
}

/// Maps each UTF-16 unit of a new text to the old unit whose styling it inherits:
/// unchanged units keep their own index, replacements inherit from the first
/// replaced unit and pure insertions from the unit before them. The result never
/// decreases, so a style range [s, e) maps to [lowerBound(s), lowerBound(e)).
enum TextDiff {
    private static let maxEditDistance = 2000
    private static let newline = UInt16(UInt8(ascii: "\n"))

    static func origins(_ old: [UInt16], _ new: [UInt16]) -> [Int] {
        let n = old.count, m = new.count
        var kept = [Int](repeating: -1, count: m)
        var prefix = 0
        while prefix < n && prefix < m && old[prefix] == new[prefix] { kept[prefix] = prefix; prefix += 1 }
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix && old[n - 1 - suffix] == new[m - 1 - suffix] {
            kept[m - 1 - suffix] = n - 1 - suffix; suffix += 1
        }
        if let pairs = myers(Array(old[prefix..<(n - suffix)]), Array(new[prefix..<(m - suffix)])) {
            for (oldIndex, newIndex) in pairs { kept[prefix + newIndex] = prefix + oldIndex }
        }
        slideOverLineBreaks(old, new, &kept)
        var origin = [Int](repeating: 0, count: m)
        var j = 0
        while j < m {
            if kept[j] >= 0 { origin[j] = kept[j]; j += 1; continue }
            var end = j
            while end < m && kept[end] < 0 { end += 1 }
            let a = j == 0 ? 0 : kept[j - 1] + 1
            let b = end == m ? n : kept[end]
            let inherit = b > a ? a : max(a - 1, 0)
            for k in j..<end { origin[k] = min(inherit, max(n - 1, 0)) }
            j = end
        }
        return origin
    }

    /// A paragraph owns its leading line break in Samsung's markup. When an inserted
    /// or deleted block is bounded by line breaks it can align either way; prefer
    /// the alignment that starts the block at a line break, so a new line typed
    /// after a checklist item joins that checklist and a deleted line takes its own
    /// paragraph style with it.
    private static func slideOverLineBreaks(_ old: [UInt16], _ new: [UInt16], _ kept: inout [Int]) {
        let m = new.count
        var j = 0
        while j < m { // pure insertions
            if kept[j] >= 0 { j += 1; continue }
            var start = j, end = j
            while end < m && kept[end] < 0 { end += 1 }
            let next = end < m ? kept[end] : old.count
            if start > 0 && kept[start - 1] >= 0 && kept[start - 1] + 1 == next {
                while start > 0 && kept[start - 1] >= 0 && new[start - 1] == newline && new[end - 1] == newline {
                    kept[end - 1] = kept[start - 1]; kept[start - 1] = -1; start -= 1; end -= 1
                }
            }
            j = max(end, j + 1)
        }
        guard m > 0 else { return }
        for k in 1...m { // pure deletions between kept[k - 1] and kept[k]
            var left = k - 1
            if kept[left] < 0 { continue }
            if k < m && kept[k] < 0 { continue }
            var gapEnd = k < m ? kept[k] : old.count
            if gapEnd <= kept[left] + 1 { continue }
            while left >= 0 && kept[left] >= 0 && old[kept[left]] == newline && old[gapEnd - 1] == newline &&
                (left == 0 || kept[left - 1] == kept[left] - 1) {
                kept[left] = gapEnd - 1; gapEnd -= 1; left -= 1
            }
        }
    }

    /// Matching (old, new) index pairs, or nil when the edit is too large to align.
    private static func myers(_ a: [UInt16], _ b: [UInt16]) -> [(Int, Int)]? {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        for d in 0...maxD {
            trace.append(Array(v[(offset - d - 1)..<(offset + d + 2)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { return backtrack(trace, n, m) }
            }
        }
        return nil
    }

    private static func backtrack(_ trace: [[Int]], _ n: Int, _ m: Int) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            func at(_ k: Int) -> Int { v[k + d + 1] }
            let k = x - y
            let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let previousX = at(previousK)
            let previousY = previousX - previousK
            while x > previousX && y > previousY { x -= 1; y -= 1; pairs.append((x, y)) }
            x = previousX; y = previousY
        }
        return pairs
    }
}
