import Foundation
import Security
import CryptoKit

enum SigningError: Error { case message(String) }
func run() throws {
let args = CommandLine.arguments
guard args.count == 3 else { throw SigningError.message("Expected an encrypted identity and password-file path") }
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let password = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .newlines)
var keychain: SecKeychain?
guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { throw SigningError.message("No default login keychain") }
var application: SecTrustedApplication?
guard SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &application) == errSecSuccess, let application else { throw SigningError.message("Could not identify codesign") }
var access: SecAccess?
guard SecAccessCreate("Samsung Cloud Notes local signing" as CFString, [application] as CFArray, &access) == errSecSuccess, let access else { throw SigningError.message("Could not create signing-key access policy") }
var items: CFArray?
let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportExportKeychain as String: keychain, kSecImportExportAccess as String: access]
let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
      let identityValue = first[kSecImportItemIdentity as String] else { throw SigningError.message("Signing identity import failed (\(status))") }
let identity = identityValue as! SecIdentity
var certificate: SecCertificate?
guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw SigningError.message("No signing certificate imported") }
let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SamsungCloudNotes", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
try Data((digest + "\n").utf8).write(to: root.appendingPathComponent("SigningIdentity.txt"), options: [.atomic])
print("Imported persistent local code-signing identity: " + digest)

}
do { try run() } catch { fputs("Signing setup failed: \(error)\n", stderr); exit(1) }
