import Foundation
import Security
import CryptoKit

// This small helper is deliberately reused byte-for-byte across local updates.
// Its Keychain partition stays stable. Only the signed Notes app can call it.
struct Command: Decodable { var operation: String; var service: String; var data: Data? }
struct Reply: Encodable { var status: Int32; var data: Data? }
func signer(_ code: SecCode) -> String? {
    var information: CFDictionary?; var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first else { return nil }
    return Insecure.SHA1.hash(data: SecCertificateCopyData(first) as Data).map { String(format: "%02x", $0) }.joined()
}
func authorizedParent() -> Bool {
    var own: SecCode?; var parent: SecCode?; var requirement: SecRequirement?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own, let certificate = signer(own),
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: getppid())] as CFDictionary, [], &parent) == errSecSuccess, let parent,
          SecRequirementCreateWithString("identifier \"local.samsung-cloud-notes\" and certificate leaf = H\"\(certificate)\"" as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
    return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
}
func run() -> Reply {
    guard authorizedParent() else { return Reply(status: errSecAuthFailed) }
    let data = FileHandle.standardInput.readData(ofLength: 131_073)
    guard data.count <= 131_072, let command = try? JSONDecoder().decode(Command.self, from: data),
          ["local.samsung-cloud-notes.session", "local.samsung-cloud-notes.native-auth", "local.samsung-cloud-notes.signing-fixture"].contains(command.service) else { return Reply(status: errSecParam) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: command.service, kSecAttrAccount as String: "samsung"]
    switch command.operation {
    case "load":
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &value)
        return Reply(status: status, data: status == errSecSuccess ? value as? Data : nil)
    case "save":
        guard let data = command.data, data.count <= 65_536 else { return Reply(status: errSecParam) }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return Reply(status: status)
    case "delete": return Reply(status: SecItemDelete(query as CFDictionary))
    default: return Reply(status: errSecParam)
    }
}
let result = run()
if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data) }
