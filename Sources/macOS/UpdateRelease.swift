import Foundation
import CryptoKit
import Security

enum UpdateChannel: String, CaseIterable { case stable, preview }

struct NotesUpdateCheckStamp {
    let id = UUID()
    let channel: UpdateChannel
    func accepts(operation: UUID, channel current: UpdateChannel) -> Bool { operation == id && current == channel }
}

enum NotesUpdateHTTP {
    static func validate(status: Int, expectedLength: Int64, limit: Int) throws {
        switch status {
        case 200: break
        case 401,404: throw NotesError.message("This release disappeared, or this repository is private. Check again or open Releases in your signed-in browser.")
        case 403,429: throw NotesError.message("GitHub temporarily limited update requests. Try later or open Releases.")
        default: throw NotesError.message("GitHub could not complete the request (HTTP \(status)).")
        }
        guard expectedLength <= Int64(limit) else { throw NotesError.message("The update response exceeds the allowed size.") }
    }
}

/// SemVer precedence, with two-component final tags accepted for the existing v1.1 release.
struct UpdateVersion: Comparable {
    let core: [UInt64]
    let pre: [String]
    let normalized: String
    init?(_ source: String) {
        let value = source.hasPrefix("v") ? String(source.dropFirst()) : source
        let pieces = value.split(separator: "+", omittingEmptySubsequences: false)
        guard pieces.count <= 2, pieces.count == 1 || Self.identifiers(String(pieces[1])) != nil else { return nil }
        let halves = pieces[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(numbers.count), numbers.allSatisfy({ Self.number($0) != nil }) else { return nil }
        core = numbers.map { Self.number($0)! } + (numbers.count == 2 ? [0] : [])
        if halves.count == 2 {
            guard let ids = Self.identifiers(String(halves[1])), ids.allSatisfy({ !$0.allSatisfy(\.isNumber) || Self.number($0) != nil }) else { return nil }
            pre = ids
        } else { pre = [] }
        normalized = core.map(String.init).joined(separator: ".") + (pre.isEmpty ? "" : "-" + pre.joined(separator: "."))
    }
    private static func number(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), value == "0" || !value.hasPrefix("0") else { return nil }
        return UInt64(value)
    }
    private static func identifiers(_ value: String) -> [String]? {
        let ids = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) ? ids : nil
    }
    static func == (a: Self, b: Self) -> Bool { a.core == b.core && a.pre == b.pre }
    static func < (a: Self, b: Self) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
        for (x,y) in zip(a.pre,b.pre) where x != y {
            if let nx = UInt64(x), let ny = UInt64(y) { return nx < ny }
            if UInt64(x) != nil { return true }; if UInt64(y) != nil { return false }
            return x < y
        }
        return a.pre.count < b.pre.count
    }
}

struct NotesUpdateConfiguration {
    let repository: String
    let assetPrefix: String
    let bundleName: String
    let bundleID: String
    static var current: Self {
        let info = Bundle.main.infoDictionary ?? [:]
        return Self(repository: info["UpdateRepository"] as? String ?? "Clascheurduturfu/samsung-cloud-notes",
                    assetPrefix: info["UpdateAssetPrefix"] as? String ?? "SamsungCloudNotes",
                    bundleName: "Samsung Cloud Notes.app", bundleID: Bundle.main.bundleIdentifier ?? "local.samsung-cloud-notes")
    }
    var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }
    var apiURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")! }
    func trustedAsset(_ url: URL, id: Int64) -> Bool {
        url.scheme == "https" && url.host == "api.github.com" && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil && url.path == "/repos/\(repository)/releases/assets/\(id)"
    }
    static func redirect(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
        ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(url.host ?? "")
    }
    static func redirected(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, redirect(url) else { return nil }
        var result = request
        if url.host != "api.github.com" { result.setValue(nil, forHTTPHeaderField: "Authorization") }
        return result
    }
}

struct NotesGitHubRelease: Decodable {
    struct Asset: Decodable {
        var id: Int64; var name: String; var url: URL; var size: Int; var digest: String?
        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let hex = String(digest.dropFirst(7)).lowercased()
            return hex.count == 64 && hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) ? hex : nil
        }
    }
    var tag_name: String; var html_url: URL; var draft: Bool; var prerelease: Bool; var body: String?; var assets: [Asset]
    func asset(_ config: NotesUpdateConfiguration) throws -> Asset {
        guard let version = UpdateVersion(tag_name) else { throw NotesError.message("Unsupported release version.") }
        let matches = assets.filter { $0.name == "\(config.assetPrefix)-\(version.normalized)-macOS.zip" }
        guard matches.count == 1, let value = matches.first, value.id > 0, value.size > 0, value.size <= 64 * 1024 * 1024,
              value.sha256 != nil, config.trustedAsset(value.url, id: value.id) else {
            throw NotesError.message("This release has no unique, verified Mac package. Open Releases for a manual download.")
        }
        return value
    }
    static func newest(_ values: [Self], channel: UpdateChannel, installed: String, config: NotesUpdateConfiguration) -> Self? {
        guard let current = UpdateVersion(installed) else { return nil }
        return values.filter { r in
            guard !r.draft, let version = UpdateVersion(r.tag_name), version > current,
                  r.html_url.scheme == "https", r.html_url.host == "github.com", r.html_url.user == nil,
                  r.html_url.path.hasPrefix("/\(config.repository)/releases/tag/") else { return false }
            if !r.prerelease && version.pre.isEmpty { return true } // Preview also receives newer Stable releases.
            return channel == .preview && r.prerelease && !version.pre.isEmpty &&
                (r.body ?? "").contains("<!-- samsung-cloud-notes:update-channel=preview -->")
        }.max { UpdateVersion($0.tag_name)! < UpdateVersion($1.tag_name)! }
    }
}

enum NotesUpdatePackage {
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, bytes.count <= 2 * 1024 * 1024 else { throw NotesError.message("The update package could not be verified. Use Releases to install manually.") }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// This app has no bundled frameworks or legitimate bundle symlinks. ZIP64 is unnecessary at this size.
    static func inspectZIP(_ data: Data, root: String) throws {
        func bad() -> NotesError { .message("The update ZIP has unsafe paths, links, sizes or unsupported entries.") }
        func u16(_ i: Int) throws -> Int { guard i >= 0, i + 2 <= data.count else { throw bad() }; return Int(data[i]) | Int(data[i+1]) << 8 }
        func u32(_ i: Int) throws -> Int { try u16(i) | u16(i+2) << 16 }
        guard data.count >= 22 else { throw bad() }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0,data.count - 65_557), by: -1) {
            if try u32(i) == 0x06054b50, try i + 22 + u16(i+20) == data.count { end = i; break }
        }
        guard let end, try u16(end+4) == 0, try u16(end+6) == 0, try u16(end+8) == u16(end+10) else { throw bad() }
        let count = try u16(end+10), start = try u32(end+16), length = try u32(end+12)
        guard count > 0, count <= 10_000, start + length == end else { throw bad() }
        var offset = start, total = 0, seen = Set<String>()
        for _ in 0..<count {
            guard try u32(offset) == 0x02014b50 else { throw bad() }
            let flags = try u16(offset+8), method = try u16(offset+10), compressed = try u32(offset+20), expanded = try u32(offset+24)
            let nameLength = try u16(offset+28), extra = try u16(offset+30), comment = try u16(offset+32), local = try u32(offset+42)
            let next = offset + 46 + nameLength + extra + comment
            guard next <= end, flags & 1 == 0, [0,8].contains(method), expanded < 256 * 1024 * 1024,
                  let name = String(data: data[(offset+46)..<(offset+46+nameLength)], encoding: .utf8), !name.isEmpty,
                  !name.contains("\\"), !name.hasPrefix("/"), !name.contains(":"), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }),
                  name == root + "/" || name.hasPrefix(root + "/") || name.hasPrefix("__MACOSX/"),
                  seen.insert(name).inserted, try (u32(offset+38) >> 16) & 0xf000 != 0xa000,
                  try u32(local) == 0x04034b50, try u16(local+6) == flags, try u16(local+8) == method,
                  try u16(local+26) == nameLength else { throw bad() }
            let localExtra = try u16(local+28), content = local + 30 + nameLength + localExtra
            guard local >= 0, content + compressed <= start,
                  data[(local+30)..<(local+30+nameLength)] == data[(offset+46)..<(offset+46+nameLength)] else { throw bad() }
            total += expanded; guard total <= 256 * 1024 * 1024 else { throw bad() }
            offset = next
        }
        guard offset == end else { throw bad() }
    }
    static func validate(_ archive: URL, asset: NotesGitHubRelease.Asset, version: String, config: NotesUpdateConfiguration, stage: URL, current: URL) throws -> URL {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == asset.size, digest(data) == asset.sha256 else { throw NotesError.message("The download failed its size or SHA-256 integrity check.") }
        try inspectZIP(data, root: config.bundleName)
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path])
        let app = stage.appendingPathComponent(config.bundleName)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String:Any]
        guard info?["CFBundleIdentifier"] as? String == config.bundleID,
              let embedded = info?["SamsungCloudNotesVersion"] as? String, UpdateVersion(embedded) == UpdateVersion(version) else { throw NotesError.message("The app identity or embedded version differs from the selected release.") }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        guard try run("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/SamsungCloudNotes").path]).split(whereSeparator: \.isWhitespace).contains(Substring(arch)) else { throw NotesError.message("The update does not support this Mac's processor.") }
        try verifyPublisher(app, current: current)
        return app
    }
    static func verifyPublisher(_ app: URL, current: URL) throws {
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        var old: SecStaticCode?, new: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &old) == errSecSuccess, let old,
              SecCodeCopyDesignatedRequirement(old, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new,
              SecStaticCodeCheckValidity(new, [], requirement) == errSecSuccess else {
            throw NotesError.message("This update is not signed by this installation's trusted publisher. Install it manually from Releases if you intend to change signing identity.")
        }
        let helper = "Contents/Resources/CredentialStore.app/Contents/MacOS/CredentialStore"
        guard digest(try Data(contentsOf: app.appendingPathComponent(helper))) == digest(try Data(contentsOf: current.appendingPathComponent(helper))) else {
            throw NotesError.message("This package changes the saved-connection helper. A manual upgrade is required to review that permission change.")
        }
    }
}

struct NotesUpdateTransaction: Codable {
    var stage: URL; var source: URL; var target: URL
    var parentPID: Int32; var nonce: String; var version: String; var probe: Bool
    static var base: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.samsung-cloud-notes/Updates", isDirectory: true) }
    func validatePaths() throws {
        let expected = Self.base.resolvingSymlinksInPath()
        guard stage.isFileURL, source.isFileURL, target.isFileURL,
              stage.deletingLastPathComponent().resolvingSymlinksInPath().path == expected.path, UUID(uuidString:stage.lastPathComponent) != nil,
              stage.resolvingSymlinksInPath().path == stage.standardizedFileURL.path,
              source.standardizedFileURL.path == stage.appendingPathComponent("Samsung Cloud Notes.app").path,
              source.resolvingSymlinksInPath().path == source.standardizedFileURL.path,
              target.pathExtension == "app", !target.path.hasPrefix(stage.path + "/"),
              target.resolvingSymlinksInPath().path == target.standardizedFileURL.path,
              parentPID > 1, UUID(uuidString: nonce) != nil, UpdateVersion(version) != nil else { throw NotesError.message("Invalid update transaction paths.") }
    }
}
