import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Samsung inline objects (pictures and tables). Samsung marks each one with U+FFFC
// in the body text and an 'objectSpan' range naming an entry of floatingObjectList.

/// An inline object ready to show: picture bytes or table cells.
enum NoteObject: Equatable {
    case image(Data)
    case table([[String]])
}

enum SamsungAttachments {
    static let objectSpan = "objectSpan/objectSpan"

    /// The Samsung object named by each U+FFFC in `rich`, in text order (nil when unnamed).
    static func anchors(_ rich: RichText) -> [String?] {
        let units = Array(rich.text.utf16)
        var named: [Int: String] = [:]
        for range in rich.ranges where range.key == objectSpan && range.end > range.start {
            named[range.start] = range.value.split(separator: ",").first.map(String.init)
        }
        return units.indices.filter { units[$0] == 0xFFFC }.map { named[$0] }
    }

    /// Samsung object ids named by the body's anchors, including anchors that lost their character.
    static func anchoredIDs(_ rich: RichText) -> Set<String> {
        Set(rich.ranges.compactMap { range in
            range.key == objectSpan ? range.value.split(separator: ",").first.map(String.init) : nil
        })
    }

    enum Source { case image(AssetRecord), table([[String]]) }

    /// The note's inline objects by Samsung object id: tables are read at once, pictures name their asset.
    static func sources(_ document: CloudDocument) -> [String: Source] {
        var result: [String: Source] = [:]
        for object in document.resource.first("floatingObjectList")?.elements(forName: "object") ?? [] {
            let id = object.attr("id")
            guard !id.isEmpty else { continue }
            switch object.attr("type") {
            case "image":
                let imageID = object.first("fillEffect")?.attr("imageId") ?? ""
                if !imageID.isEmpty, let asset = document.assets.first(where: { $0.id == imageID }) { result[id] = .image(asset) }
            case let type where type.hasPrefix("table"):
                if let data = Data(base64Encoded: object.value("tableBinary").filter { !$0.isWhitespace }),
                   let cells = SamsungTable.cells(data), !cells.isEmpty, !(cells.first?.isEmpty ?? true) { result[id] = .table(cells) }
            default: break
            }
        }
        return result
    }
}

enum SamsungTable {
    /// Cell texts of a Samsung `tableBinary`, laid out by each cell's rectangle.
    /// Returns nil when the record does not look like a table this version understands.
    static func cells(_ data: Data) -> [[String]]? {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        func double(_ i: Int) -> Double {
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(b[i + k]) << (8 * k) }
            return Double(bitPattern: bits)
        }
        func isUUID(_ i: Int) -> Bool {
            guard i + 36 <= b.count else { return false }
            for k in 0..<36 {
                let c = b[i + k]
                if [8, 13, 18, 23].contains(k) { if c != 0x2d { return false } }
                else if !((0x30...0x39).contains(c) || (0x61...0x66).contains(c)) { return false }
            }
            return true
        }
        // Every object starts with its identifier: a 16-bit length (36) and the UUID text.
        var markers: [Int] = []
        var i = 0
        while i + 38 <= b.count {
            if b[i] == 36, b[i + 1] == 0, isUUID(i + 2) { markers.append(i); i += 38 } else { i += 1 }
        }
        guard markers.count >= 2 else { return nil }
        struct Cell { var left, top: Double; var text: String }
        var cells: [Cell] = []
        for (index, start) in markers.enumerated().dropFirst() {
            let end = index + 1 < markers.count ? markers[index + 1] : b.count
            let rect = start + 38 + 8
            guard rect + 32 <= end else { return nil }
            let left = double(rect), top = double(rect + 8), right = double(rect + 16), bottom = double(rect + 24)
            guard [left, top, right, bottom].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1_000_000 }), right > left, bottom > top else { return nil }
            // Text record: 0x0006, byte size, UTF-16 length, UTF-16LE characters.
            var text = ""
            var j = rect + 32
            while j + 10 <= end {
                if b[j] == 6, b[j + 1] == 0 {
                    let size = u32(j + 2), count = u32(j + 6)
                    if count > 0, count <= 100_000, size >= 2 * count + 64, size <= 2 * count + 65_536, j + 10 + 2 * count <= end {
                        let units = (0..<count).map { UInt16(b[j + 10 + 2 * $0]) | UInt16(b[j + 11 + 2 * $0]) << 8 }
                        let candidate = String(decoding: units, as: UTF16.self)
                        if !candidate.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) {
                            text = candidate; break
                        }
                    }
                }
                j += 1
            }
            cells.append(Cell(left: left, top: top, text: text))
        }
        func key(_ value: Double) -> Int { Int((value * 2).rounded()) }
        let columns = Array(Set(cells.map { key($0.left) })).sorted(), rows = Array(Set(cells.map { key($0.top) })).sorted()
        guard columns.count <= 100, rows.count <= 1000 else { return nil }
        var grid = Array(repeating: Array(repeating: "", count: columns.count), count: rows.count)
        for cell in cells {
            guard let r = rows.firstIndex(of: key(cell.top)), let c = columns.firstIndex(of: key(cell.left)) else { continue }
            grid[r][c] = cell.text.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
        return grid
    }
}
