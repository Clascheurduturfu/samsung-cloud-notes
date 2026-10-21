import Foundation
#if os(macOS)
import AppKit
#endif
import SwiftUI
#if canImport(FoundationXML)
import FoundationXML
#endif

// A small read-only preview of the cloud's strokeBinary records. The cloud
// envelope was examined directly; sdocx's published format research was also
// consulted for channel/framing interpretation. No upstream code is bundled.
// Advanced pen effects and non-stroke page objects are outside this renderer.
private struct InkBytes {
    let bytes: [UInt8]
    var position = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, position <= bytes.count, count <= bytes.count - position else { throw NotesError.message("Incomplete drawing data.") }
        defer { position += count }
        return Data(bytes[position..<(position + count)])
    }
    mutating func integer(_ count: Int) throws -> UInt64 {
        let data = try take(count)
        return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    mutating func number(_ count: Int) throws -> Double {
        let bits = try integer(count)
        let result = count == 8 ? Double(bitPattern: bits) : Double(Float(bitPattern: UInt32(bits)))
        guard result.isFinite, abs(result) < 10_000_000 else { throw NotesError.message("Unsupported drawing coordinate.") }
        return result
    }
}

private struct InkFrame {
    let kind: Int
    let properties: [UInt8]
    let fields: [UInt8]
    let fixed: Data
    let flexible: Data
    static func bit(_ bytes: [UInt8], _ index: Int) -> Bool { index / 8 < bytes.count && bytes[index / 8] & (1 << (index % 8)) != 0 }
    init(_ stream: inout InkBytes) throws {
        let length = Int(try stream.integer(4))
        guard length >= 12, length <= 16_000_000 else { throw NotesError.message("Unsupported drawing frame.") }
        var header = InkBytes(try stream.take(length - 4))
        kind = Int(try header.integer(2))
        let split = Int(try header.integer(4))
        let propertyLength = Int(try header.integer(1))
        properties = Array(try header.take(propertyLength))
        let fieldLength = Int(try header.integer(1))
        fields = Array(try header.take(fieldLength))
        let fixedEnd = split == 0 && fields.allSatisfy({ $0 == 0 }) ? length : split
        guard fixedEnd >= header.position + 4, fixedEnd <= length else { throw NotesError.message("Invalid drawing frame bounds.") }
        fixed = try header.take(fixedEnd - 4 - header.position)
        flexible = try header.take(length - fixedEnd)
    }
}

struct InkStroke {
    let points: [CGPoint]
    let color: UInt32
    let width: Double
    init(_ data: Data) throws {
        var stream = InkBytes(data)
        guard try stream.integer(4) == 0xffffffff, try stream.integer(4) == 4,
              try stream.integer(4) == 4000 else { throw NotesError.message("Unsupported cloud stroke version.") }
        let base = try InkFrame(&stream)
        let ink = try InkFrame(&stream)
        guard base.kind == 0, ink.kind == 1, InkFrame.bit(base.properties, 3), !InkFrame.bit(ink.properties, 3) else { throw NotesError.message("Unsupported or hidden drawing stroke.") }
        if InkFrame.bit(base.fields, 0) {
            var extra = InkBytes(base.flexible)
            guard abs(try extra.number(4)) < 0.001 else { throw NotesError.message("Rotated strokes are not supported in this preview.") }
        }
        var channel = InkBytes(ink.fixed)
        let count = Int(try channel.integer(2))
        let compressed = InkFrame.bit(ink.properties, 0)
        let stylus = InkFrame.bit(ink.properties, 2)
        let expected = count == 0 ? 0 : compressed ? 16 + (count - 1) * 4 + (stylus ? 4 : 2) * (4 + (count - 1) * 2) : count * (stylus ? 32 : 24)
        guard count > 0, count <= 65535, channel.bytes.count - channel.position == expected + 2 else { throw NotesError.message("Unsupported drawing point channels.") }
        var decoded: [CGPoint] = []
        var x = 0.0, y = 0.0
        for index in 0..<count {
            if compressed && index > 0 {
                let dx = try channel.integer(2), dy = try channel.integer(2)
                x += Double(dx & 0x7fff) / 32 * (dx & 0x8000 == 0 ? 1 : -1)
                y += Double(dy & 0x7fff) / 32 * (dy & 0x8000 == 0 ? 1 : -1)
            } else { x = try channel.number(8); y = try channel.number(8) }
            guard abs(x) < 1_000_000, abs(y) < 1_000_000 else { throw NotesError.message("Drawing lies outside preview bounds.") }
            decoded.append(CGPoint(x: x, y: y))
        }
        points = decoded
        var pressure = try channel.number(4)
        var totalPressure = max(0, min(1, pressure))
        for _ in 1..<count {
            if compressed {
                let raw = try channel.integer(2)
                pressure += Double(raw & 0x7fff) / 4096 * (raw & 0x8000 == 0 ? 1 : -1)
            } else { pressure = try channel.number(4) }
            totalPressure += max(0, min(1, pressure))
        }
        var style = InkBytes(ink.flexible)
        if InkFrame.bit(ink.fields, 0) { _ = try style.take(4) }
        if InkFrame.bit(ink.fields, 1) { _ = try style.take(4) }
        color = InkFrame.bit(ink.fields, 2) ? UInt32(try style.integer(4)) : 0xff000000
        let penWidth = InkFrame.bit(ink.fields, 3) ? try style.number(4) : 1
        guard penWidth >= 0, penWidth <= 1000 else { throw NotesError.message("Unsupported drawing pen size.") }
        width = max(0.3, penWidth * max(0.15, totalPressure / Double(count)))
    }
}

struct DrawingPage: Identifiable {
    var id: Int
    var width: Double
    var height: Double
    var background: UInt32
    var strokes: [InkStroke]
    var unsupported = 0
    init?(_ page: XMLElement, index: Int) {
        id = index
        width = Double(page.attr("width")) ?? 720
        height = Double(page.attr("height")) ?? 1080
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 100_000, height <= 100_000 else { return nil }
        background = UInt32(truncatingIfNeeded: Int64(page.attr("bgColor")) ?? -1)
        strokes = []
        for layer in page.first("layerList")?.elements(forName: "layer") ?? [] where layer.attr("visible") != "false" {
            let objects = (try? layer.nodes(forXPath: ".//objectList/object")) as? [XMLElement] ?? []
            for object in objects {
                guard object.attr("type") == "stroke", let data = Data(base64Encoded: object.value("strokeBinary")), data.count <= 16_000_000,
                      let stroke = try? InkStroke(data) else { unsupported += 1; continue }
                strokes.append(stroke)
            }
        }
        guard !strokes.isEmpty || unsupported > 0 else { return nil }
    }
    func draw(in context: CGContext) {
        context.setFillColor(Self.cgColor(background)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            context.setStrokeColor(Self.cgColor(stroke.color)); context.setFillColor(Self.cgColor(stroke.color)); context.setLineWidth(stroke.width)
            if stroke.points.count == 1 { context.fillEllipse(in: CGRect(x: first.x - stroke.width / 2, y: first.y - stroke.width / 2, width: stroke.width, height: stroke.width)); continue }
            context.beginPath(); context.move(to: first)
            for point in stroke.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
    }
    static func cgColor(_ argb: UInt32) -> CGColor {
        CGColor(red: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255, alpha: CGFloat((argb >> 24) & 255) / 255)
    }
    static func pdf(_ pages: [DrawingPage]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw NotesError.message("Could not prepare the drawing preview.") }
        for page in pages {
            let box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            context.beginPDFPage([kCGPDFContextMediaBox as String: withUnsafeBytes(of: box) { Data($0) }] as CFDictionary)
            context.translateBy(x: 0, y: page.height); context.scaleBy(x: 1, y: -1)
            page.draw(in: context); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}

struct DrawingPreview: View {
    let pages: [DrawingPage]
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Text("Drawing preview · pen effects may differ").font(.caption).foregroundStyle(.secondary)
                ForEach(pages) { page in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Page \(page.id + 1)").font(.caption).foregroundStyle(.secondary)
                        Canvas(rendersAsynchronously: true) { context, size in
                            context.withCGContext { cg in cg.scaleBy(x: size.width / page.width, y: size.height / page.height); page.draw(in: cg) }
                        }.aspectRatio(page.width / page.height, contentMode: .fit).border(.secondary.opacity(0.2))
                        if page.unsupported > 0 { Text("\(page.unsupported) page objects cannot be previewed yet. Their original data is retained.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
