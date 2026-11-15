import Foundation

// Read-only support for the classic single-page .sdocx container. Page framing
// follows Dietrich's published MIT-licensed format documentation; the stroke
// payload uses the existing cloud stroke decoder. Unsupported layouts fail closed.
enum StickyMemoPreview {
    private static let limit = 32 * 1024 * 1024
    private static func runUnzip(_ args: [String], limit: Int) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var result = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            if chunk.count > limit - result.count {
                if process.isRunning { process.terminate() }; pipe.fileHandleForReading.closeFile(); process.waitUntilExit()
                throw NotesError.message("The attached note is too large to preview.")
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesError.message("The attached note archive could not be read.") }
        return result
    }
    static func selfTest() throws {
        // Synthetic classic page containing one supported stroke.
        let fixture = Data(base64Encoded: "/////wQAAACgDwAADQAAAAAADQAAAAEIAEoAAAABAEIAAAABAAEMAgAAAAAAAAAkQAAAAAAAADRAAAAAAAAAPkAAAAAAAABEQAAAAD8AAEA/AAAAAAoAAAACAFY0Ev8AAEBA")!
        let payload = fixture.dropFirst(12)
        var data = Data(repeating: 0, count: 140)
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 255) }
        }
        func append(_ value: UInt32, _ count: Int) {
            for i in 0..<count { data.append(UInt8((value >> (8 * i)) & 255)) }
        }
        put(140, at: 0); put(128, at: 4); put(0x70, at: 14)
        put(720, at: 22); put(1080, at: 26); put(0xfff0e0d0, at: 132)
        append(1, 2); append(0, 2) // layer count and current layer
        append(16, 4); append(0, 4); append(0, 4); append(0, 4) // layer header
        append(1, 4); append(1, 1); append(0, 2); append(UInt32(payload.count + 32), 4)
        data.append(contentsOf: payload); data.append(Data(repeating: 0, count: 64))
        data.append(Data("Page for SAMSUNG S-Pen SDK".utf8))
        let page = try parsePage(data)
        guard page.strokes.count == 1, page.strokes[0].points.count == 2, page.background == 0xfff0e0d0 else { throw NotesError.message("Attached note handwriting test failed.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scnotes-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("fixture.page"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory; zip.arguments = ["-q", "fixture.zip", "fixture.page"]
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw NotesError.message("Could not create attachment test archive.") }
        let archive = try Data(contentsOf: directory.appendingPathComponent("fixture.zip"))
        guard try render(archive).starts(with: Data("%PDF".utf8)) else { throw NotesError.message("Attached note archive preview failed.") }
        do { _ = try render(Data("invalid".utf8)); throw NotesError.message("Invalid attachment was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Invalid attachment was accepted." { throw error } }
        do { _ = try parsePage(data.prefix(80)); throw NotesError.message("Truncated attached note was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Truncated attached note was accepted." { throw error } }
    }
    static func render(_ data: Data) throws -> Data {
        guard data.count <= limit, data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw NotesError.message("This attachment is not a supported Samsung Notes archive.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scnotes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("note.sdocx")
        try data.write(to: archive, options: .atomic)
        let list = try runUnzip(["-Z1", archive.path], limit: 256 * 1024)
        guard let names = String(data: list, encoding: .utf8) else { throw NotesError.message("Unsupported archive filenames.") }
        let pages = names.split(separator: "\n").map(String.init).filter { $0.lowercased().hasSuffix(".page") }
        guard pages.count == 1, pages[0].range(of: "^[A-Za-z0-9_-]+[.]page$", options: .regularExpression) != nil else {
            throw NotesError.message("Only single-page Samsung Notes attachments are supported in this handwriting preview.")
        }
        let pageData = try runUnzip(["-p", archive.path, pages[0]], limit: limit)
        return try DrawingPage.pdf([parsePage(pageData)])
    }
    static func parsePage(_ data: Data) throws -> DrawingPage {
        let bytes = [UInt8](data)
        func read(_ offset: Int, _ size: Int) throws -> UInt64 {
            guard offset >= 0, size > 0, size <= 8, offset <= bytes.count, size <= bytes.count - offset else { throw NotesError.message("The attached note page is incomplete.") }
            return (0..<size).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        guard data.suffix(26) == Data("Page for SAMSUNG S-Pen SDK".utf8) else { throw NotesError.message("This Samsung note page format is not supported yet.") }
        let layerOffset = Int(try read(0, 4)), propertyOffset = Int(try read(4, 4))
        let width = Double(try read(22, 4)), height = Double(try read(26, 4)), mask = try read(14, 4)
        guard width > 0, height > 0, width <= 100_000, height <= 100_000, propertyOffset >= 18, layerOffset > propertyOffset, layerOffset < bytes.count else { throw NotesError.message("Invalid attached note page dimensions or offsets.") }
        // Background is only decoded for the observed simple-property layout.
        var background: UInt32 = 0xffffffff
        if mask & 0x0e == 0 {
            let colorOffset = propertyOffset + (mask & 1 != 0 ? 32 : 0) + (mask & 0x10 != 0 ? 4 : 0)
            if mask & 0x20 != 0 {
                guard colorOffset <= layerOffset - 4 else { throw NotesError.message("Invalid note background.") }
                background = UInt32(try read(colorOffset, 4))
            }
        }
        let layerCount = Int(try read(layerOffset, 2)); guard (1...64).contains(layerCount) else { throw NotesError.message("Unsupported note layers.") }
        var cursor = layerOffset + 4, strokes: [InkStroke] = [], unsupported = 0
        for _ in 0..<layerCount {
            let start = cursor, headerSize = Int(try read(start, 4))
            let hidden = try read(start + 9, 1) & 1 != 0
            guard headerSize >= 16, headerSize <= bytes.count - start else { throw NotesError.message("Invalid note layer.") }
            cursor = start + headerSize
            let count = Int(try read(cursor, 4)); cursor += 4
            guard count <= 100_000 else { throw NotesError.message("Too many objects in the attached note.") }
            for _ in 0..<count {
                let type = try read(cursor, 1), children = try read(cursor + 1, 2), size = Int(try read(cursor + 3, 4))
                guard children == 0, size >= 32, cursor <= bytes.count - 7, size <= bytes.count - cursor - 7 else { throw NotesError.message("Unsupported nested or incomplete note object.") }
                let begin = cursor + 7, end = begin + size - 32
                if !hidden {
                    if type == 1 || type == 15 {
                        var payload = Data([255,255,255,255,4,0,0,0,160,15,0,0]); payload.append(contentsOf: bytes[begin..<end])
                        if let stroke = try? InkStroke(payload, pageFile: true) { strokes.append(stroke) } else { unsupported += 1 }
                    } else { unsupported += 1 }
                }
                cursor = begin + size
            }
            guard cursor <= bytes.count - 32 else { throw NotesError.message("The attached note layer is incomplete.") }; cursor += 32
        }
        guard !strokes.isEmpty else { throw NotesError.message("No supported handwriting was found in this attachment.") }
        // Semitransparent strokes beneath ink keep highlighted handwriting legible.
        strokes = strokes.filter { $0.color >> 24 < 255 } + strokes.filter { $0.color >> 24 == 255 }
        return DrawingPage(id: 0, width: width, height: height, background: background, strokes: strokes, unsupported: unsupported)
    }
}
