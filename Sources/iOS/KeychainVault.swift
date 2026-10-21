import Foundation
import Security

/// iOS apps are sandboxed with their own Keychain access group, so credentials
/// are stored directly instead of through the Mac's signed helper process.
/// Items never leave this device and are unavailable before first unlock.
enum CredentialError: LocalizedError {
    case status(Int32)
    var errorDescription: String? {
        if case .status(let status) = self {
            if status == errSecItemNotFound { return "Sign in with Samsung to get started." }
            return "Keychain could not access the Samsung connection (\(status)). Unlock this device and try again."
        }
        return nil
    }
}

enum CredentialVault {
    static let services: Set<String> = ["local.samsung-cloud-notes.session", "local.samsung-cloud-notes.native-auth"]
    static func perform(_ operation: String, service: String, data: Data? = nil) throws -> Data? {
        guard services.contains(service) else { throw CredentialError.status(errSecParam) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "samsung"]
        switch operation {
        case "load":
            var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            guard status == errSecSuccess else { throw CredentialError.status(status) }
            return value as? Data
        case "save":
            guard let data, data.count <= 65_536 else { throw CredentialError.status(errSecParam) }
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query; add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw CredentialError.status(status) }
            return nil
        case "delete":
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.status(status) }
            return nil
        default: throw CredentialError.status(errSecParam)
        }
    }
}
