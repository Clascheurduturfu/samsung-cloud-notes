import Foundation

enum NotesUpdateSelfTest {
    @MainActor static func runState() async throws {
        let name = "local.samsung-cloud-notes.update-test."+UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        var waiting: CheckedContinuation<Data,Never>?
        let updater = NotesAppUpdates(preferences:defaults,fetch:{ _ in await withCheckedContinuation { waiting = $0 } })
        updater.channel = .preview; updater.automaticallyCheck = true
        updater.check()
        for _ in 0..<100 where waiting == nil { await Task.yield() }
        guard let response = waiting else { throw NotesError.message("Updater fixture did not start.") }
        updater.channel = .stable
        let expectedStatus = updater.status
        response.resume(returning:Data("[]".utf8))
        for _ in 0..<20 { await Task.yield() }
        guard updater.status == expectedStatus, updater.release == nil, !updater.busy else { throw NotesError.message("A stale channel response changed update state.") }
        let reopened = NotesAppUpdates(preferences:defaults)
        guard reopened.channel == .stable, reopened.automaticallyCheck else { throw NotesError.message("Update preferences did not survive recreation.") }
        updater.release = NotesGitHubRelease(tag_name:"9.0.0",html_url:URL(string:"https://github.com/Clascheurduturfu/samsung-cloud-notes/releases/tag/v9.0.0")!,draft:false,prerelease:false,body:"fixture",assets:[])
        let model = NotesModel(); model.busy = true
        updater.install(model:model)
        guard !updater.busy, !updater.installing, model.busy else { throw NotesError.message("Updater interrupted a critical app operation.") }
        print("Updater stale-response, persisted-preference and critical-activity checks passed.")
    }
    static func run() throws {
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw NotesError.message("Updater test: " + message) }
        }
        func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        try expect(UpdateVersion("1.2.0-beta.10")! > UpdateVersion("1.2.0-beta.9")!, "numeric prerelease order")
        try expect(UpdateVersion("1.2.0")! > UpdateVersion("1.2.0-rc.9")!, "final follows prerelease")
        try expect(UpdateVersion("v1.1")! == UpdateVersion("1.1.0")!, "legacy release normalization")
        try expect(UpdateVersion("1.2.0+build.1")! == UpdateVersion("1.2.0+build.2")!, "build metadata precedence")
        for bad in ["latest","1.2.0-beta..1","01.2.0","1.2.0-beta.01","1.2.0+","1.2.0-beta/1"] { try expect(UpdateVersion(bad) == nil,"unsupported version \(bad)") }
        let config = NotesUpdateConfiguration(repository:"owner/notes",assetPrefix:"Notes",bundleName:"Samsung Cloud Notes.app",bundleID:"local.samsung-cloud-notes")
        func release(_ tag: String, preview: Bool = false, draft: Bool = false) -> NotesGitHubRelease {
            let v = UpdateVersion(tag)!.normalized
            return NotesGitHubRelease(tag_name:tag,html_url:URL(string:"https://github.com/owner/notes/releases/tag/\(tag)")!,draft:draft,prerelease:preview,
                body:preview ? "<!-- samsung-cloud-notes:update-channel=preview -->" : "",
                assets:[.init(id:42,name:"Notes-\(v)-macOS.zip",url:URL(string:"https://api.github.com/repos/owner/notes/releases/assets/42")!,size:12,digest:"sha256:"+String(repeating:"a",count:64))])
        }
        let values = [release("1.1.0"),release("1.2.0-beta.9",preview:true),release("1.2.0-beta.10",preview:true),release("9.0.0",draft:true)]
        try expect(NotesGitHubRelease.newest(values,channel:.stable,installed:"1.0.0",config:config)?.tag_name == "1.1.0","Stable excludes previews/drafts")
        try expect(NotesGitHubRelease.newest(values,channel:.preview,installed:"1.0.0",config:config)?.tag_name == "1.2.0-beta.10","Preview highest numeric version")
        try expect(NotesGitHubRelease.newest(values+[release("1.2.0")],channel:.preview,installed:"1.2.0-beta.10",config:config)?.tag_name == "1.2.0","Preview accepts newer Stable")
        try expect(NotesGitHubRelease.newest(values,channel:.stable,installed:"1.2.0-beta.10",config:config) == nil,"channel switch does not downgrade")
        var badRelease = release("1.3.0-beta.1",preview:true); badRelease.body = "unrelated prerelease"
        try expect(NotesGitHubRelease.newest([badRelease],channel:.preview,installed:"1.0.0",config:config) == nil,"Preview stream provenance")
        var assetRelease = release("1.2.0"); _ = try assetRelease.asset(config)
        assetRelease.assets[0].digest = nil
        try expect(rejects { _ = try assetRelease.asset(config) },"missing digest refused")
        assetRelease = release("1.2.0"); assetRelease.assets += assetRelease.assets
        try expect(rejects { _ = try assetRelease.asset(config) },"ambiguous package refused")
        assetRelease.assets = []
        try expect(rejects { _ = try assetRelease.asset(config) },"missing package refused")
        try expect(!config.trustedAsset(URL(string:"https://api.github.com/repos/other/notes/releases/assets/42")!,id:42),"asset belongs to configured repository")
        var redirected = URLRequest(url:URL(string:"https://release-assets.githubusercontent.com/file")!)
        redirected.setValue("Bearer fixture",forHTTPHeaderField:"Authorization")
        try expect(NotesUpdateConfiguration.redirected(redirected)?.value(forHTTPHeaderField:"Authorization") == nil,"strip credentials outside API host")
        try expect(!NotesUpdateConfiguration.redirect(URL(string:"https://githubusercontent.com.attacker.example/file")!),"untrusted redirect refused")
        let stamp = NotesUpdateCheckStamp(channel:.preview)
        try expect(stamp.accepts(operation:stamp.id,channel:.preview) && !stamp.accepts(operation:stamp.id,channel:.stable) && !stamp.accepts(operation:UUID(),channel:.preview),"stale channel response refused")
        try expect(rejects { try NotesUpdateHTTP.validate(status:404,expectedLength:20,limit:100) },"deleted rolling release requires a fresh check")
        try expect(rejects { try NotesUpdateHTTP.validate(status:200,expectedLength:101,limit:100) },"download byte limit")
        try expect(NotesUpdatePackage.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","SHA-256 reference")
        // Minimal stored ZIP, to exercise the actual pre-extraction parser.
        func zip(_ name: String, expanded: UInt32 = 1, mode: UInt32 = 0x81a40000) -> Data {
            var out = Data()
            func n16(_ x: UInt16) { out.append(UInt8(x & 255)); out.append(UInt8(x >> 8)) }
            func n32(_ x: UInt32) { n16(UInt16(x & 65535)); n16(UInt16(x >> 16)) }
            let bytes = Data(name.utf8)
            n32(0x04034b50); n16(20); n16(0); n16(0); n16(0); n16(0); n32(0); n32(1); n32(expanded); n16(UInt16(bytes.count)); n16(0); out.append(bytes); out.append(0)
            let start = UInt32(out.count)
            n32(0x02014b50); n16(0x0314); n16(20); n16(0); n16(0); n16(0); n16(0); n32(0); n32(1); n32(expanded); n16(UInt16(bytes.count)); n16(0); n16(0); n16(0); n16(0); n32(mode); n32(0); out.append(bytes)
            let length = UInt32(out.count)-start
            n32(0x06054b50); n16(0); n16(0); n16(1); n16(1); n32(length); n32(start); n16(0)
            return out
        }
        try NotesUpdatePackage.inspectZIP(zip("Samsung Cloud Notes.app/Contents/file"),root:config.bundleName)
        for name in ["/Samsung Cloud Notes.app/file","Samsung Cloud Notes.app/../../escape","Samsung Cloud Notes.app\\..\\escape","Other.app/file"] {
            try expect(rejects { try NotesUpdatePackage.inspectZIP(zip(name),root:config.bundleName) },"unsafe ZIP path")
        }
        try expect(rejects { try NotesUpdatePackage.inspectZIP(zip("Samsung Cloud Notes.app/link",mode:0xa1ff0000),root:config.bundleName) },"ZIP symlink refused")
        try expect(rejects { try NotesUpdatePackage.inspectZIP(zip("Samsung Cloud Notes.app/big",expanded:300*1024*1024),root:config.bundleName) },"expanded ZIP limit")
        try expect(rejects { try NotesUpdatePackage.inspectZIP(Data("corrupt".utf8),root:config.bundleName) },"corrupt ZIP refused")
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("scnotes-update-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:fixtureDirectory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:fixtureDirectory) }
        let fixtureZIP = fixtureDirectory.appendingPathComponent("bad-digest.zip"), bytes = zip("Samsung Cloud Notes.app/Contents/file")
        try bytes.write(to:fixtureZIP)
        var asset = release("1.2.0").assets[0]; asset.size = bytes.count
        try expect(rejects { _ = try NotesUpdatePackage.validate(fixtureZIP,asset:asset,version:"1.2.0",config:config,stage:fixtureDirectory,current:fixtureDirectory) },"digest mismatch refused before extraction")
        print("Updater version, channel, asset, redirect, digest and ZIP safety checks passed.")
    }
}
