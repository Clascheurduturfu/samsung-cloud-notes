import Foundation
import Security
import CryptoKit

/// The fixed helper preserves its own Keychain identity across locally signed
/// app updates. Both sides check the other process's signing certificate.
enum CredentialError: LocalizedError {
    case status(Int32)
    var errorDescription: String? {
        if case .status(let status) = self {
            if status == errSecItemNotFound { return "Sign in with Samsung to get started." }
            return "Keychain could not access the Samsung connection (\(status)). Unlock your Mac and allow Samsung Cloud Notes Credential Store to access its saved sign-in."
        }
        return nil
    }
}

enum CredentialVault {
    struct Command: Encodable { var operation: String; var service: String; var data: Data? }
    struct Reply: Decodable { var status: Int32; var data: Data? }
    static var helper: URL? { Bundle.main.resourceURL?.appendingPathComponent("CredentialStore.app/Contents/MacOS/CredentialStore") }
    static func perform(_ operation: String, service: String, data: Data? = nil) throws -> Data? {
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else { throw NotesError.message("The app's Keychain helper is missing. Reinstall Samsung Cloud Notes.") }
        var own: SecCode?; var ownStatic: SecStaticCode?; var info: CFDictionary?; var target: SecStaticCode?; var requirement: SecRequirement?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first else { throw NotesError.message("This app needs a persistent signing identity to use Keychain.") }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &target) == errSecSuccess, let target,
              SecRequirementCreateWithString("identifier \"local.samsung-cloud-notes.credentials\" and certificate leaf = H\"\(hash)\"" as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(target, [], requirement) == errSecSuccess else { throw NotesError.message("The Keychain helper's signature does not match this app.") }
        let process = Process(); process.executableURL = helper
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(Command(operation: operation, service: service, data: data)))
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, response.count <= 131_072, let reply = try? JSONDecoder().decode(Reply.self, from: response) else { throw NotesError.message("The Keychain helper could not complete its request.") }
        if operation == "delete", reply.status == errSecItemNotFound { return nil }
        guard reply.status == errSecSuccess else { throw CredentialError.status(reply.status) }
        return reply.data
    }
}
