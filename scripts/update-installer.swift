import Foundation
import Security
import Darwin

#if UPDATE_INSTALLER
enum NotesError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// No elevation, shell interpolation or access to the credential store.
enum NotesBundleSwap {
    static func perform(source: URL, target: URL, nonce: String, launch: (URL,Bool) throws -> Void, healthy: () -> Bool) throws {
        let fm = FileManager.default
        let next = target.deletingLastPathComponent().appendingPathComponent(".SamsungNotes-next-\(nonce).app")
        let old = target.deletingLastPathComponent().appendingPathComponent(".SamsungNotes-previous-\(nonce).app")
        guard !fm.fileExists(atPath:next.path), !fm.fileExists(atPath:old.path) else { throw NotesError.message("An update transaction already occupies the destination.") }
        try fm.copyItem(at:source,to:next)
        defer { try? fm.removeItem(at:next) }
        try fm.moveItem(at:target,to:old)
        do {
            try fm.moveItem(at:next,to:target)
            try launch(target,false)
            guard healthy() else { throw NotesError.message("The new app did not acknowledge a healthy launch.") }
        } catch {
            // Retain the old app until the UI sends a transaction-specific acknowledgement.
            if fm.fileExists(atPath:target.path) { try fm.removeItem(at:target) }
            try fm.moveItem(at:old,to:target)
            try? launch(target,true)
            throw error
        }
        try fm.removeItem(at:old)
    }
    static func selfTest() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("scnotes-swap-test-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true); defer { try? fm.removeItem(at:root) }
        let source = root.appendingPathComponent("new.app"), target = root.appendingPathComponent("current.app")
        try fm.createDirectory(at:source,withIntermediateDirectories:true); try fm.createDirectory(at:target,withIntermediateDirectories:true)
        try Data("new".utf8).write(to:source.appendingPathComponent("marker")); try Data("old".utf8).write(to:target.appendingPathComponent("marker"))
        var launches = 0
        do { try perform(source:source,target:target,nonce:UUID().uuidString,launch:{ _,_ in launches += 1 },healthy:{false}); throw NotesError.message("Rollback test accepted an unhealthy app.") }
        catch { guard try Data(contentsOf:target.appendingPathComponent("marker")) == Data("old".utf8), launches == 2 else { throw error } }
        try perform(source:source,target:target,nonce:UUID().uuidString,launch:{ _,_ in },healthy:{true})
        guard try Data(contentsOf:target.appendingPathComponent("marker")) == Data("new".utf8),
              try fm.contentsOfDirectory(atPath:root.path).count == 2 else { throw NotesError.message("Successful swap failed to clean its owned backup.") }
        print("Update installer swap, health-failure rollback and cleanup tests passed.")
    }
}

@main struct NotesUpdateInstaller {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--self-test" {
            do { try NotesBundleSwap.selfTest(); exit(0) } catch { fputs("Installer self-test failed: \(error.localizedDescription)\n",stderr); exit(1) }
        }
        var transaction: NotesUpdateTransaction?
        do {
            guard CommandLine.arguments.count == 2 else { throw NotesError.message("Expected an update transaction file.") }
            let file = URL(fileURLWithPath:CommandLine.arguments[1])
            let value = try JSONDecoder().decode(NotesUpdateTransaction.self,from:Data(contentsOf:file)); transaction = value
            try value.validatePaths()
            guard file.standardizedFileURL.path == value.stage.appendingPathComponent("transaction.json").path else { throw NotesError.message("Invalid update configuration location.") }
            let info = NSDictionary(contentsOf:value.source.appendingPathComponent("Contents/Info.plist"))
            let current = NSDictionary(contentsOf:value.target.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == "local.samsung-cloud-notes",
                  current?["CFBundleIdentifier"] as? String == "local.samsung-cloud-notes",
                  info?["SamsungCloudNotesVersion"] as? String == value.version else { throw NotesError.message("The candidate app changed after validation.") }
            try NotesUpdatePackage.verifyPublisher(value.source,current:value.target)
            for _ in 0..<120 {
                if kill(value.parentPID,0) != 0 { break }
                usleep(250_000)
            }
            guard kill(value.parentPID,0) != 0 else { throw NotesError.message("The running app did not quit; it was left unchanged.") }
            try NotesBundleSwap.perform(source:value.source,target:value.target,nonce:value.nonce,launch:{ app,rollback in
                var args = ["-n","-a",app.path]
                if !rollback { args += ["--args","--update-transaction",file.path]; if value.probe { args += ["--update-probe"] } }
                else if value.probe { return } // Isolated tests must not open the old live account UI.
                let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/open"); process.arguments = args
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NotesError.message("Launch Services could not open the updated app.") }
            },healthy:{
                for _ in 0..<120 {
                    if let bytes = try? Data(contentsOf:value.stage.appendingPathComponent("ready.json")),
                       let d = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                       d["nonce"] as? String == value.nonce, d["version"] as? String == value.version,
                       let pid = d["pid"] as? Int32, kill(pid,0) == 0 { return true }
                    usleep(250_000)
                }
                return false
            })
            try result(value,success:true,message:"Installed \(value.version) and confirmed app startup.")
            try FileManager.default.removeItem(at:value.stage)
            exit(0)
        } catch {
            if let value = transaction, (try? value.validatePaths()) != nil {
                try? result(value,success:false,message:"Update failed or was rolled back: " + error.localizedDescription)
            }
            exit(1)
        }
    }
    static func result(_ value: NotesUpdateTransaction, success: Bool, message: String) throws {
        let data = try JSONSerialization.data(withJSONObject:["success":success,"version":value.version,"message":message])
        try data.write(to:NotesUpdateTransaction.base.appendingPathComponent("last-result.json"),options:.atomic)
    }
}
#endif
