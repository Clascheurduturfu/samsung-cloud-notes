import Foundation
import AppKit
import AuthenticationServices
import CommonCrypto
import CryptoKit
import Security

// Samsung's account bootstrap protocol was cross-checked against the MIT-licensed
// samsung-re-health implementation by Charles Bel. See third-party notices.
struct NativeCredentials: Codable {
    var authServer: String
    var masterToken: String
    var userID: String
    var loginID: String
    var deviceID: String
    var accessToken = ""
    var refreshToken = ""
    var accessExpires = Date.distantPast
    var registrationID = ""
    var registeredAppVersion = ""
    var cloudAuthorization = ""
    var cloudExpires = Date.distantPast
    var cacheID: String { "native:" + userID + ":" + deviceID }
}

extension NativeCredentials {
    private enum CodingKeys: String, CodingKey { case authServer, masterToken, userID, loginID, deviceID, accessToken, refreshToken, accessExpires, cloudAuthorization, cloudExpires, registrationID, registeredAppVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authServer = try c.decode(String.self, forKey: .authServer); masterToken = try c.decode(String.self, forKey: .masterToken)
        userID = try c.decode(String.self, forKey: .userID); loginID = try c.decode(String.self, forKey: .loginID); deviceID = try c.decode(String.self, forKey: .deviceID)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""; refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        accessExpires = try c.decodeIfPresent(Date.self, forKey: .accessExpires) ?? .distantPast
        registrationID = try c.decodeIfPresent(String.self, forKey: .registrationID) ?? ""
        registeredAppVersion = try c.decodeIfPresent(String.self, forKey: .registeredAppVersion) ?? ""
        cloudAuthorization = try c.decodeIfPresent(String.self, forKey: .cloudAuthorization) ?? ""
        cloudExpires = try c.decodeIfPresent(Date.self, forKey: .cloudExpires) ?? .distantPast
    }
}

enum SamsungAuthCrypto {
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NotesError.message("Could not generate secure sign-in state.") }
        return data
    }
    static func url64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func challenge(_ value: String) -> String { url64(Data(SHA256.hash(data: Data(value.utf8)))) }
    static func aes(_ input: Data, key: Data, iv: Data? = nil, encrypt: Bool, ecb: Bool = false) throws -> Data {
        guard key.count == 16, iv == nil || iv?.count == 16 else { throw NotesError.message("Invalid Samsung encryption parameters.") }
        var output = Data(count: input.count + kCCBlockSizeAES128); let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { bytes in key.withUnsafeBytes { secret in
            func crypt(_ vector: UnsafeRawPointer?) -> CCCryptorStatus {
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0)), secret.baseAddress, key.count, vector, bytes.baseAddress, input.count, out.baseAddress, capacity, &written)
            }
            if let iv { return iv.withUnsafeBytes { crypt($0.baseAddress) } }
            return crypt(nil)
        } } }
        guard status == kCCSuccess else { throw NotesError.message("Samsung sign-in encryption could not be processed.") }
        return output.prefix(written)
    }
    static func callback(_ value: String, key: String) throws -> String {
        guard value.count <= 32_768, value.count % 2 == 0 else { throw NotesError.message("Invalid Samsung sign-in callback.") }
        var bytes = Data(); var at = value.startIndex
        while at < value.endIndex {
            let end = value.index(at, offsetBy: 2)
            guard let byte = UInt8(value[at..<end], radix: 16) else { throw NotesError.message("Invalid Samsung sign-in callback encoding.") }
            bytes.append(byte); at = end
        }
        var secret = Data(key.utf8.prefix(16)); secret.append(Data(repeating: 0, count: 16 - secret.count))
        guard let text = String(data: try aes(bytes, key: secret, encrypt: false, ecb: true), encoding: .utf8) else { throw NotesError.message("Samsung returned unreadable sign-in data.") }
        return text
    }
    static func envelope(_ payload: [String: Any], iterations: Int, publicKey: String) throws -> String {
        guard (1...1_000_000).contains(iterations), let der = Data(base64Encoded: publicKey) else { throw NotesError.message("Samsung returned invalid sign-in key material.") }
        let password = Data(SHA256.hash(data: Data(String(iterations).utf8))).base64EncodedString()
        let salt = try random(16); var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { output in salt.withUnsafeBytes { input in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, input.bindMemory(to: UInt8.self).baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), output.bindMemory(to: UInt8.self).baseAddress!, 16)
        } }
        guard status == kCCSuccess else { throw NotesError.message("Could not prepare Samsung sign-in encryption.") }
        // SecKey accepts PKCS#1. The entry point supplies an SPKI wrapper.
        func part(_ data: Data, _ position: inout Int) throws -> (UInt8, Data) {
            guard position + 2 <= data.count else { throw NotesError.message("Invalid Samsung public key.") }
            let tag = data[position]; position += 1; var length = Int(data[position]); position += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), position + count <= data.count else { throw NotesError.message("Invalid Samsung public key length.") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(data[position]); position += 1 }
            }
            guard length <= data.count - position else { throw NotesError.message("Truncated Samsung public key.") }
            let value = data.subdata(in: position..<position + length); position += length
            return (tag, value)
        }
        var position = 0; let (_, sequence) = try part(der, &position); position = 0
        _ = try part(sequence, &position); let (tag, bits) = try part(sequence, &position)
        guard tag == 3, bits.first == 0 else { throw NotesError.message("Samsung returned an unsupported public key.") }
        var error: Unmanaged<CFError>?
        guard let rsa = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error),
              let encryptedKey = SecKeyCreateEncryptedData(rsa, .rsaEncryptionPKCS1, Data(key.base64EncodedString().utf8) as CFData, &error) as Data? else { throw NotesError.message("Could not encrypt the Samsung sign-in key.") }
        let iv = try random(16)
        let encrypted = try aes(JSONSerialization.data(withJSONObject: payload), key: key, iv: iv, encrypt: true)
        let envelope = ["chkDoNum": String(iterations), "svcEncParam": encrypted.base64EncodedString(), "svcEncKY": encryptedKey.base64EncodedString(), "svcEncIV": iv.map { String(format: "%02x", $0) }.joined()]
        return try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
    }
}

struct SamsungHTTPError: LocalizedError {
    let status: Int
    let path: String
    let message: String
    var errorDescription: String? { message }
}

private final class AuthRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class SamsungSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SamsungSignIn()
    static let masterClient = "yfrtglt53o"
    static let notesClient = "tcl0p60gnz"
    static let redirect = "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358"
    private var web: ASWebAuthenticationSession?
    private var renewal: Task<AccountSession, Error>?
    private let transport = URLSession(configuration: .ephemeral, delegate: AuthRedirectGuard(), delegateQueue: nil)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }
    private func request(_ url: URL, form: [String: String]? = nil, json: [String: Any]? = nil, headers: [String: String] = [:], method: String? = nil) async throws -> [String: Any] {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host, host == "account.samsung.com" || host.hasSuffix(".samsungosp.com") || host == "api.samsungcloud.com" || host == "play.samsungcloud.com" else { throw NotesError.message("Samsung returned an untrusted sign-in destination.") }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.httpMethod = method ?? (form == nil && json == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            var parts = URLComponents(); parts.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data(parts.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == url else { throw NotesError.message("Samsung sign-in returned an unexpected destination.") }
        guard (200..<300).contains(response.statusCode) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = failure?["rcode"]
            let detail = (failure?["rmsg"] as? String).flatMap { $0.hasPrefix("Request body ") || $0.hasPrefix("Request header ") ? " " + String($0.prefix(180)) : nil } ?? ""
            throw SamsungHTTPError(status: response.statusCode, path: url.path, message: "Samsung sign-in step \(url.path) failed (HTTP \(response.statusCode)\(code.map { ", code \($0)" } ?? "")).\(detail)")
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotesError.message("Samsung returned an unsupported sign-in response.") }
        return result
    }
    private func browser(_ url: URL) async throws -> URL {
        guard web == nil else { throw NotesError.message("A Samsung sign-in is already open.") }
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ms-app") { [weak self] callback, error in
                Task { @MainActor in
                    guard !completed else { return }; completed = true
                    self?.web = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: NotesError.message(error is ASWebAuthenticationSessionError ? "Samsung sign-in was cancelled." : "Samsung sign-in did not complete.")) }
                }
            }
            web = session; session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start(), !completed { completed = true; web = nil; continuation.resume(throwing: NotesError.message("macOS could not open Samsung sign-in.")) }
        }
    }
    func signIn(status: (String) -> Void) async throws -> NativeCredentials {
        status("Preparing Samsung sign-in…")
        let entry = try await request(URL(string: "https://account.samsung.com/accounts/ANDROIDSDK/getEntryPoint")!)
        guard let signIn = entry["signInURI"] as? String, let uri = URL(string: signIn), uri.scheme == "https", uri.host == "account.samsung.com", uri.path.hasPrefix("/accounts/"), uri.query == nil, uri.fragment == nil,
              let key = entry["pkiPublicKey"] as? String, let rounds = Int(String(describing: entry["chkDoNum"] ?? "")) else { throw NotesError.message("Samsung returned incomplete sign-in configuration.") }
        let state = String(SamsungAuthCrypto.url64(try SamsungAuthCrypto.random(15)).prefix(20))
        let verifier = SamsungAuthCrypto.url64(try SamsungAuthCrypto.random(32))
        let previous = try NativeAuthStore.loadIfPresent()
        let device = previous?.deviceID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // The SDK entry point whitelists Android browser package identifiers even
        // on macOS. This compatibility value selects its standard web flow;
        // the actual browser, device name and OS remain those of this Mac.
        let payload: [String: Any] = ["clientId": Self.masterClient, "code_challenge": SamsungAuthCrypto.challenge(verifier), "code_challenge_method": "S256", "competitorDeviceYNFlag": "Y", "countryCode": "fr", "deviceInfo": "Google|com.android.chrome", "deviceModelID": "Mac", "deviceName": "Samsung Cloud Notes for Mac", "deviceOSVersion": ProcessInfo.processInfo.operatingSystemVersionString, "devicePhysicalAddressText": "MAC:" + device, "deviceType": "APP", "deviceUniqueID": device, "redirect_uri": Self.redirect, "replaceableClientConnectYN": "N", "replaceableClientId": "", "replaceableDevicePhysicalAddressText": "", "responseEncryptionType": "1", "responseEncryptionYNFlag": "Y", "scope": "", "state": state, "svcIptLgnID": "", "iosYNFlag": "Y"]
        var target = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        target.queryItems = [URLQueryItem(name: "locale", value: "en-US"), URLQueryItem(name: "svcParam", value: try SamsungAuthCrypto.envelope(payload, iterations: rounds, publicKey: key)), URLQueryItem(name: "mode", value: "C")]
        let started = Date(); status("Complete sign-in in Samsung's secure browser window…")
        let callback = try await browser(target.url!)
        let expected = URL(string: Self.redirect)!
        guard callback.scheme == expected.scheme, callback.host == expected.host, callback.path == expected.path, callback.user == nil, callback.password == nil, Date().timeIntervalSince(started) < 900,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw NotesError.message("Samsung sign-in returned an invalid or expired callback.") }
        var items = parts.queryItems ?? []
        if let fragment = parts.fragment { var extra = URLComponents(); extra.percentEncodedQuery = fragment; items += extra.queryItems ?? [] }
        func field(_ name: String) throws -> String {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            guard values.count == 1, !values[0].isEmpty else { throw NotesError.message("Samsung sign-in omitted \(name).") }
            return values[0]
        }
        let responseKey = try SamsungAuthCrypto.callback(field("state"), key: state)
        let authority = try SamsungAuthCrypto.callback(field("auth_server_url"), key: responseKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = authority.contains("://") ? authority : "https://" + authority
        let candidate = URL(string: normalized)
        guard let server = candidate, server.scheme?.lowercased() == "https", server.query == nil, server.fragment == nil, server.path.isEmpty || server.path == "/", server.user == nil, server.password == nil, server.port == nil || server.port == 443,
              let host = server.host?.lowercased(), host == "account.samsung.com" || host == "samsungosp.com" || host.hasSuffix(".samsungosp.com") else {
            let safeHost = candidate?.host ?? "invalid host"
            throw NotesError.message("Samsung returned an untrusted account server: \(safeHost), scheme \(candidate?.scheme ?? "none"), path \(candidate?.path ?? "none").")
        }
        let code = try SamsungAuthCrypto.callback(field("code"), key: responseKey)
        let login = try SamsungAuthCrypto.callback(field("retValue"), key: responseKey)
        status("Authorizing this Mac with Samsung…")
        let secureServer = URL(string: "https://" + host)!
        let result = try await request(secureServer.appendingPathComponent("auth/oauth2/authenticate"), form: ["grant_type": "authorization_code", "serviceType": "M", "client_id": Self.masterClient, "code": code, "code_verifier": verifier, "username": login, "physical_address_text": device])
        guard let token = (result["userauth_token"] ?? result["userAuthToken"]) as? String, let user = (result["userId"] ?? result["user_id"]) as? String, !token.isEmpty, !user.isEmpty else { throw NotesError.message("Samsung did not issue a reusable account connection.") }
        var credentials = NativeCredentials(authServer: "https://" + host, masterToken: token, userID: user, loginID: login, deviceID: device)
        if let previous, previous.userID == user { credentials.registrationID = previous.registrationID; credentials.registeredAppVersion = previous.registeredAppVersion }
        try NativeAuthStore.save(credentials)
        return credentials
    }
    func authorizeNotes(_ original: NativeCredentials) async throws -> NativeCredentials {
        var value = original
        let verifier = SamsungAuthCrypto.url64(try SamsungAuthCrypto.random(32))
        var target = URLComponents(string: value.authServer + "/auth/oauth2/v2/authorize")!
        target.queryItems = ["response_type": "code", "serviceType": "M", "client_id": Self.notesClient, "code_challenge": SamsungAuthCrypto.challenge(verifier), "code_challenge_method": "S256", "childAccountSupported": "Y", "userauth_token": value.masterToken, "physical_address_text": value.deviceID, "login_id": value.loginID].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let authorization = try await request(target.url!)
        guard let code = authorization["code"] as? String else { throw NotesError.message("Samsung did not authorize Notes for this Mac.") }
        if let authData = authorization["auth_data"] as? [String: Any], let user = authData["userId"] as? String { value.userID = user }
        let token = try await request(URL(string: value.authServer + "/auth/oauth2/token")!, form: ["grant_type": "authorization_code", "code": code, "client_id": Self.notesClient, "client_secret": "", "physical_address_text": value.deviceID, "code_verifier": verifier])
        return try self.token(token, updating: value)
    }
    private func headers(_ credentials: NativeCredentials) -> [String: String] {
        ["x-sc-app-id": Self.notesClient, "x-sc-access-token": credentials.accessToken, "x-sc-uid": credentials.userID, "User-Agent": "SamsungCloudNotes-macOS/" + appVersion]
    }
    private func token(_ response: [String: Any], updating original: NativeCredentials) throws -> NativeCredentials {
        guard let access = response["access_token"] as? String, !access.isEmpty else { throw NotesError.message("Samsung did not issue a Notes access token.") }
        var value = original; value.accessToken = access
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { value.refreshToken = refresh }
        guard !value.refreshToken.isEmpty else { throw NotesError.message("Samsung did not issue Notes renewal credentials.") }
        value.accessExpires = Date().addingTimeInterval((response["expires_in"] as? NSNumber)?.doubleValue ?? Double(response["expires_in"] as? String ?? "") ?? 3600)
        try NativeAuthStore.save(value)
        return value
    }
    func cloudSession(_ original: NativeCredentials, force: Bool = false) async throws -> AccountSession {
        var value = original
        if value.accessToken.isEmpty { value = try await authorizeNotes(value) }
        else if force || value.accessExpires < Date().addingTimeInterval(120) {
            do {
                let response = try await request(URL(string: value.authServer + "/auth/oauth2/token")!, form: ["grant_type": "refresh_token", "refresh_token": value.refreshToken, "client_id": Self.notesClient, "client_secret": "", "physical_address_text": value.deviceID])
                value = try token(response, updating: value)
            } catch let error as SamsungHTTPError where [400, 401, 403].contains(error.status) {
                value = try await authorizeNotes(value)
            }
        }
        var h = headers(value); h["x-sc-cdid"] = SHA256.hash(data: Data(value.deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        h["x-sc-app-version"] = appShortVersion
        if value.registrationID.isEmpty || value.registeredAppVersion != appShortVersion {
            // This server accepts the Android SDK compatibility profile, while
            // retaining an explicit Mac model/alias. No Android code is bundled.
            let registration = try await request(URL(string: "https://play.samsungcloud.com/identity/v1/register")!, json: ["app": ["version": appShortVersion], "device": ["osType": "android", "osVersion": "35", "platformVersion": "6.0.0", "type": "phone", "countryCode": "FRA", "modelName": "Mac", "alias": "Samsung Cloud Notes for Mac", "osUserId": "0"]], headers: h)
            guard let id = registration["registrationId"] as? String, !id.isEmpty else { throw NotesError.message("Samsung did not issue a Notes registration ID.") }
            value.registrationID = id; value.registeredAppVersion = appShortVersion
            value.cloudAuthorization = ""; value.cloudExpires = .distantPast
            try NativeAuthStore.save(value)
        }
        if force || value.cloudAuthorization.isEmpty || value.cloudExpires < Date().addingTimeInterval(120) {
            let token = try await request(URL(string: "https://play.samsungcloud.com/identity/v1/tokens")!, headers: h, method: "POST")
            guard let access = token["accessToken"] as? String, !access.isEmpty, let kind = token["tokenType"] as? String, kind.lowercased() == "bearer" else { throw NotesError.message("Samsung did not issue a Notes cloud token.") }
            value.cloudAuthorization = "Bearer " + access
            let expiry = (token["expiresAt"] as? NSNumber)?.doubleValue ?? Double(token["expiresAt"] as? String ?? "") ?? 0
            value.cloudExpires = Date(timeIntervalSince1970: expiry > 100_000_000_000 ? expiry / 1000 : expiry)
            try NativeAuthStore.save(value)
        }
        return AccountSession(authorization: value.cloudAuthorization, account: value.loginID, nativeID: value.cacheID, expiresAt: value.cloudExpires)
    }
    func signOut() throws {
        renewal?.cancel(); renewal = nil
        web?.cancel(); web = nil
        try NativeAuthStore.delete()
        try SessionStore.delete()
    }
    func renew(_ session: AccountSession, force: Bool = false) async throws -> AccountSession {
        guard let id = session.nativeID else { return session }
        if !force, let expiry = session.expiresAt, expiry > Date().addingTimeInterval(120) { return session }
        if let renewal {
            let result = try await renewal.value
            guard result.nativeID == id else { throw NotesError.message("The Samsung account changed during renewal. Reconnect before continuing.") }
            return result
        }
        let task = Task { @MainActor in
            let credentials = try NativeAuthStore.load()
            guard credentials.cacheID == id else { throw NotesError.message("This connection belongs to another Samsung sign-in. Sign in again.") }
            let updated = try await self.cloudSession(credentials, force: force)
            try Task.checkCancellation()
            try SessionStore.save(updated)
            return updated
        }
        renewal = task; defer { renewal = nil }
        return try await task.value
    }

}

enum NativeAuthStore {
    static let service = "local.samsung-cloud-notes.native-auth"
    static func save(_ value: NativeCredentials) throws { _ = try CredentialVault.perform("save", service: service, data: JSONEncoder().encode(value)) }
    static func load() throws -> NativeCredentials {
        guard let data = try CredentialVault.perform("load", service: service) else { throw CredentialError.status(errSecItemNotFound) }
        return try JSONDecoder().decode(NativeCredentials.self, from: data)
    }
    static func loadIfPresent() throws -> NativeCredentials? {
        do { return try load() } catch CredentialError.status(errSecItemNotFound) { return nil }
    }
    static func delete() throws { _ = try CredentialVault.perform("delete", service: service) }
}
