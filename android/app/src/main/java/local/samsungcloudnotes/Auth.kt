package local.samsungcloudnotes

import android.os.Build
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.SecureRandom
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

// Port of Sources/Shared/Authentication.swift. Samsung's account bootstrap
// protocol was cross-checked against the MIT-licensed samsung-re-health
// implementation by Charles Bel. See docs/THIRD_PARTY_NOTICES.md.

val appVersion: String = BuildConfig.APP_VERSION
val appShortVersion: String = appVersion.substringBefore('-')

object ClientPlatform {
    val model: String get() = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"
    const val deviceName = "Samsung Cloud Notes for Android"
    val userAgent: String get() = "SamsungCloudNotes-Android/$appVersion"
}

data class NativeCredentials(
    val authServer: String,
    val masterToken: String,
    var userID: String,
    val loginID: String,
    val deviceID: String,
    var accessToken: String = "",
    var refreshToken: String = "",
    var accessExpires: Long = 0,
    var registrationID: String = "",
    var registeredAppVersion: String = "",
    var cloudAuthorization: String = "",
    var cloudExpires: Long = 0,
) {
    val cacheID: String get() = "native:$userID:$deviceID"
    fun toJson(): String = JSONObject().put("authServer", authServer).put("masterToken", masterToken).put("userID", userID).put("loginID", loginID)
        .put("deviceID", deviceID).put("accessToken", accessToken).put("refreshToken", refreshToken).put("accessExpires", accessExpires)
        .put("registrationID", registrationID).put("registeredAppVersion", registeredAppVersion).put("cloudAuthorization", cloudAuthorization)
        .put("cloudExpires", cloudExpires).toString()
    companion object {
        fun fromJson(text: String): NativeCredentials {
            val j = JSONObject(text)
            return NativeCredentials(j.getString("authServer"), j.getString("masterToken"), j.getString("userID"), j.getString("loginID"), j.getString("deviceID"),
                j.optString("accessToken"), j.optString("refreshToken"), j.optLong("accessExpires"), j.optString("registrationID"),
                j.optString("registeredAppVersion"), j.optString("cloudAuthorization"), j.optLong("cloudExpires"))
        }
    }
}

object SamsungAuthCrypto {
    private val random = SecureRandom()
    fun random(count: Int) = ByteArray(count).also { random.nextBytes(it) }
    fun url64(data: ByteArray): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(data)
    fun challenge(value: String): String = url64(sha256(value.toByteArray()))

    fun aes(input: ByteArray, key: ByteArray, iv: ByteArray? = null, encrypt: Boolean, ecb: Boolean = false): ByteArray {
        if (key.size != 16 || (iv != null && iv.size != 16)) throw NotesException("Invalid Samsung encryption parameters.")
        return try {
            val cipher = Cipher.getInstance(if (ecb) "AES/ECB/PKCS5Padding" else "AES/CBC/PKCS5Padding")
            val mode = if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE
            if (ecb) cipher.init(mode, SecretKeySpec(key, "AES")) else cipher.init(mode, SecretKeySpec(key, "AES"), IvParameterSpec(iv ?: ByteArray(16)))
            cipher.doFinal(input)
        } catch (_: Exception) { throw NotesException("Samsung sign-in encryption could not be processed.") }
    }

    fun callback(value: String, key: String): String {
        if (value.length > 32_768 || value.length % 2 != 0) throw NotesException("Invalid Samsung sign-in callback.")
        val bytes = ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toIntOrNull(16)?.toByte() ?: throw NotesException("Invalid Samsung sign-in callback encoding.")
        }
        val secret = key.toByteArray().copyOf(16) // first 16 UTF-8 bytes, zero padded
        return strictUtf8(aes(bytes, secret, encrypt = false, ecb = true)) ?: throw NotesException("Samsung returned unreadable sign-in data.")
    }

    fun envelope(payload: JSONObject, iterations: Int, publicKey: String): String {
        val der = base64Decode(publicKey)
        if (iterations !in 1..1_000_000 || der == null) throw NotesException("Samsung returned invalid sign-in key material.")
        val password = base64(sha256(iterations.toString().toByteArray()))
        val salt = random(16)
        val key = try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(PBEKeySpec(password.toCharArray(), salt, iterations, 128)).encoded
        } catch (_: Exception) { throw NotesException("Could not prepare Samsung sign-in encryption.") }
        val encryptedKey = try {
            val rsa = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(der))
            Cipher.getInstance("RSA/ECB/PKCS1Padding").apply { init(Cipher.ENCRYPT_MODE, rsa) }.doFinal(base64(key).toByteArray())
        } catch (_: Exception) { throw NotesException("Could not encrypt the Samsung sign-in key.") }
        val iv = random(16)
        val encrypted = aes(payload.toString().toByteArray(), key, iv, encrypt = true)
        val envelope = JSONObject().put("chkDoNum", iterations.toString()).put("svcEncParam", base64(encrypted))
            .put("svcEncKY", base64(encryptedKey)).put("svcEncIV", iv.hex())
        return base64(envelope.toString().toByteArray())
    }
}

class SamsungHttpException(val status: Int, val path: String, message: String) : Exception(message)

object SamsungSignIn {
    const val masterClient = "yfrtglt53o"
    const val notesClient = "tcl0p60gnz"
    const val redirect = "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358"

    /** Opens Samsung's page in the user's browser and returns the ms-app callback. Set by the activity. */
    var browser: (suspend (String) -> String)? = null
    private val renewal = Mutex()

    private fun encode(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    private fun formEncode(values: Map<String, String>) = values.toSortedMap().entries.joinToString("&") { "${encode(it.key)}=${encode(it.value)}" }

    private suspend fun request(address: String, form: Map<String, String>? = null, json: JSONObject? = null,
                                headers: Map<String, String> = emptyMap(), method: String? = null): JSONObject = withContext(Dispatchers.IO) {
        val url = URL(address)
        val host = url.host
        if (url.protocol != "https" || url.userInfo != null || (url.port != -1 && url.port != 443) ||
            !(host == "account.samsung.com" || host.endsWith(".samsungosp.com") || host == "api.samsungcloud.com" || host == "play.samsungcloud.com")) {
            throw NotesException("Samsung returned an untrusted sign-in destination.")
        }
        val all = headers.toMutableMap()
        all["Accept"] = "application/json"
        var body: ByteArray? = null
        if (form != null) { body = formEncode(form).toByteArray(); all["Content-Type"] = "application/x-www-form-urlencoded" }
        if (json != null) { body = json.toString().toByteArray(); all["Content-Type"] = "application/json" }
        val verb = method ?: if (form == null && json == null) "GET" else "POST"
        if (verb == "POST" && body == null) body = ByteArray(0)
        val (status, data) = Http.send(address, verb, all, body, followRedirects = false, timeoutMillis = 30_000)
        if (status !in 200..299) {
            val failure = runCatching { JSONObject(String(data)) }.getOrNull()
            val code = failure?.opt("rcode")
            val detail = failure?.optString("rmsg")?.takeIf { it.startsWith("Request body ") || it.startsWith("Request header ") }?.let { " " + it.take(180) } ?: ""
            throw SamsungHttpException(status, url.path, "Samsung sign-in step ${url.path} failed (HTTP $status${code?.let { ", code $it" } ?: ""}).$detail")
        }
        runCatching { JSONObject(String(data)) }.getOrNull() ?: throw NotesException("Samsung returned an unsupported sign-in response.")
    }

    private fun queryItems(raw: String?): List<Pair<String, String>> = raw.orEmpty().split('&').filter { it.isNotEmpty() }.map { item ->
        val name = item.substringBefore('='); val value = if ('=' in item) item.substringAfter('=') else ""
        percentDecode(name) to percentDecode(value)
    }
    private fun percentDecode(value: String): String {
        val out = java.io.ByteArrayOutputStream(); var i = 0
        while (i < value.length) {
            val byte = if (value[i] == '%' && i + 2 < value.length) value.substring(i + 1, i + 3).toIntOrNull(16) else null
            if (byte != null) { out.write(byte); i += 3 } else { out.write(value[i].toString().toByteArray()); i++ }
        }
        return String(out.toByteArray())
    }

    suspend fun signIn(status: (String) -> Unit): NativeCredentials {
        status("Preparing Samsung sign-in…")
        val entry = request("https://account.samsung.com/accounts/ANDROIDSDK/getEntryPoint")
        val signIn = runCatching { URI(entry.optString("signInURI")) }.getOrNull()
        val key = entry.optString("pkiPublicKey")
        val rounds = entry.opt("chkDoNum")?.toString()?.toIntOrNull()
        if (signIn == null || signIn.scheme != "https" || signIn.host != "account.samsung.com" || signIn.path?.startsWith("/accounts/") != true ||
            signIn.rawQuery != null || signIn.rawFragment != null || key.isEmpty() || rounds == null) throw NotesException("Samsung returned incomplete sign-in configuration.")
        val state = SamsungAuthCrypto.url64(SamsungAuthCrypto.random(15)).take(20)
        val verifier = SamsungAuthCrypto.url64(SamsungAuthCrypto.random(32))
        val previous = NativeAuthStore.loadOrNull()
        val device = previous?.deviceID ?: UUID.randomUUID().toString().replace("-", "").lowercase()
        // The same SDK entry point and compatibility flags as the Mac client; on
        // Android the browser identifier also describes the real default browser family.
        val payload = JSONObject(mapOf("clientId" to masterClient, "code_challenge" to SamsungAuthCrypto.challenge(verifier), "code_challenge_method" to "S256",
            "competitorDeviceYNFlag" to "Y", "countryCode" to "fr", "deviceInfo" to "Google|com.android.chrome", "deviceModelID" to ClientPlatform.model,
            "deviceName" to ClientPlatform.deviceName, "deviceOSVersion" to "Android ${Build.VERSION.RELEASE}", "devicePhysicalAddressText" to "MAC:$device",
            "deviceType" to "APP", "deviceUniqueID" to device, "redirect_uri" to redirect, "replaceableClientConnectYN" to "N", "replaceableClientId" to "",
            "replaceableDevicePhysicalAddressText" to "", "responseEncryptionType" to "1", "responseEncryptionYNFlag" to "Y", "scope" to "", "state" to state,
            "svcIptLgnID" to "", "iosYNFlag" to "Y"))
        val target = signIn.toString() + "?locale=en-US&svcParam=" + encode(SamsungAuthCrypto.envelope(payload, rounds, key)) + "&mode=C"
        val started = System.currentTimeMillis(); status("Complete sign-in in Samsung's browser page…")
        val open = browser ?: throw NotesException("This device could not open Samsung sign-in.")
        val callback = URI(open(target))
        val expected = URI(redirect)
        if (callback.scheme != expected.scheme || callback.host != expected.host || !(callback.rawPath.isNullOrEmpty() || callback.rawPath == "/") ||
            callback.rawUserInfo != null || System.currentTimeMillis() - started > 900_000) throw NotesException("Samsung sign-in returned an invalid or expired callback.")
        val items = queryItems(callback.rawQuery) + queryItems(callback.rawFragment)
        fun field(name: String): String {
            val values = items.filter { it.first == name }.map { it.second }
            if (values.size != 1 || values[0].isEmpty()) throw NotesException("Samsung sign-in omitted $name.")
            return values[0]
        }
        val responseKey = SamsungAuthCrypto.callback(field("state"), state)
        val authority = SamsungAuthCrypto.callback(field("auth_server_url"), responseKey).trim()
        val candidate = runCatching { URI(if ("://" in authority) authority else "https://$authority") }.getOrNull()
        val host = candidate?.host?.lowercase()
        if (candidate == null || candidate.scheme?.lowercase() != "https" || candidate.rawQuery != null || candidate.rawFragment != null ||
            !(candidate.rawPath.isNullOrEmpty() || candidate.rawPath == "/") || candidate.rawUserInfo != null || (candidate.port != -1 && candidate.port != 443) ||
            host == null || !(host == "account.samsung.com" || host == "samsungosp.com" || host.endsWith(".samsungosp.com"))) {
            throw NotesException("Samsung returned an untrusted account server: ${candidate?.host ?: "invalid host"}.")
        }
        val code = SamsungAuthCrypto.callback(field("code"), responseKey)
        val login = SamsungAuthCrypto.callback(field("retValue"), responseKey)
        status("Authorizing this device with Samsung…")
        val result = request("https://$host/auth/oauth2/authenticate", form = mapOf("grant_type" to "authorization_code", "serviceType" to "M",
            "client_id" to masterClient, "code" to code, "code_verifier" to verifier, "username" to login, "physical_address_text" to device))
        val token = result.optString("userauth_token").ifEmpty { result.optString("userAuthToken") }
        val user = result.optString("userId").ifEmpty { result.optString("user_id") }
        if (token.isEmpty() || user.isEmpty()) throw NotesException("Samsung did not issue a reusable account connection.")
        val credentials = NativeCredentials("https://$host", token, user, login, device)
        if (previous != null && previous.userID == user) { credentials.registrationID = previous.registrationID; credentials.registeredAppVersion = previous.registeredAppVersion }
        NativeAuthStore.save(credentials)
        return credentials
    }

    private suspend fun authorizeNotes(original: NativeCredentials): NativeCredentials {
        val value = original.copy()
        val verifier = SamsungAuthCrypto.url64(SamsungAuthCrypto.random(32))
        val query = mapOf("response_type" to "code", "serviceType" to "M", "client_id" to notesClient, "code_challenge" to SamsungAuthCrypto.challenge(verifier),
            "code_challenge_method" to "S256", "childAccountSupported" to "Y", "userauth_token" to value.masterToken,
            "physical_address_text" to value.deviceID, "login_id" to value.loginID)
        val authorization = request(value.authServer + "/auth/oauth2/v2/authorize?" + formEncode(query))
        val code = authorization.optString("code").ifEmpty { throw NotesException("Samsung did not authorize Notes for this device.") }
        authorization.optJSONObject("auth_data")?.optString("userId")?.takeIf { it.isNotEmpty() }?.let { value.userID = it }
        val token = request(value.authServer + "/auth/oauth2/token", form = mapOf("grant_type" to "authorization_code", "code" to code,
            "client_id" to notesClient, "client_secret" to "", "physical_address_text" to value.deviceID, "code_verifier" to verifier))
        return token(token, value)
    }

    private fun token(response: JSONObject, original: NativeCredentials): NativeCredentials {
        val access = response.optString("access_token").ifEmpty { throw NotesException("Samsung did not issue a Notes access token.") }
        val value = original.copy(accessToken = access)
        response.optString("refresh_token").takeIf { it.isNotEmpty() }?.let { value.refreshToken = it }
        if (value.refreshToken.isEmpty()) throw NotesException("Samsung did not issue Notes renewal credentials.")
        val seconds = response.opt("expires_in")?.toString()?.toDoubleOrNull() ?: 3600.0
        value.accessExpires = System.currentTimeMillis() + (seconds * 1000).toLong()
        NativeAuthStore.save(value)
        return value
    }

    suspend fun cloudSession(original: NativeCredentials, force: Boolean = false): AccountSession {
        var value = original.copy()
        val now = System.currentTimeMillis()
        if (value.accessToken.isEmpty()) value = authorizeNotes(value)
        else if (force || value.accessExpires < now + 120_000) {
            value = try {
                token(request(value.authServer + "/auth/oauth2/token", form = mapOf("grant_type" to "refresh_token", "refresh_token" to value.refreshToken,
                    "client_id" to notesClient, "client_secret" to "", "physical_address_text" to value.deviceID)), value)
            } catch (error: SamsungHttpException) {
                if (error.status !in setOf(400, 401, 403)) throw error
                authorizeNotes(value)
            }
        }
        val headers = mapOf("x-sc-app-id" to notesClient, "x-sc-access-token" to value.accessToken, "x-sc-uid" to value.userID,
            "User-Agent" to ClientPlatform.userAgent, "x-sc-cdid" to sha256(value.deviceID.toByteArray()).hex(), "x-sc-app-version" to appShortVersion)
        if (value.registrationID.isEmpty() || value.registeredAppVersion != appShortVersion) {
            // The accepted registration profile is the server's Android SDK
            // profile (verified with SDK 35 / platform 6.0.0), with this device's model.
            val body = JSONObject().put("app", JSONObject().put("version", appShortVersion)).put("device", JSONObject().put("osType", "android")
                .put("osVersion", "35").put("platformVersion", "6.0.0").put("type", "phone").put("countryCode", "FRA")
                .put("modelName", ClientPlatform.model).put("alias", ClientPlatform.deviceName).put("osUserId", "0"))
            val registration = request("https://play.samsungcloud.com/identity/v1/register", json = body, headers = headers)
            val id = registration.optString("registrationId").ifEmpty { throw NotesException("Samsung did not issue a Notes registration ID.") }
            value.registrationID = id; value.registeredAppVersion = appShortVersion
            value.cloudAuthorization = ""; value.cloudExpires = 0
            NativeAuthStore.save(value)
        }
        if (force || value.cloudAuthorization.isEmpty() || value.cloudExpires < System.currentTimeMillis() + 120_000) {
            val token = request("https://play.samsungcloud.com/identity/v1/tokens", headers = headers, method = "POST")
            val access = token.optString("accessToken")
            if (access.isEmpty() || !token.optString("tokenType").equals("bearer", ignoreCase = true)) throw NotesException("Samsung did not issue a Notes cloud token.")
            value.cloudAuthorization = "Bearer $access"
            val expiry = token.opt("expiresAt")?.toString()?.toDoubleOrNull() ?: 0.0
            value.cloudExpires = if (expiry > 100_000_000_000) expiry.toLong() else (expiry * 1000).toLong()
            NativeAuthStore.save(value)
        }
        return AccountSession(value.cloudAuthorization, value.loginID, value.cacheID, value.cloudExpires)
    }

    fun signOut() {
        NativeAuthStore.delete()
        SessionStore.delete()
    }

    suspend fun renew(session: AccountSession, force: Boolean = false): AccountSession {
        val id = session.nativeID ?: return session
        val soon = System.currentTimeMillis() + 120_000
        if (!force && (session.expiresAt ?: 0) > soon) return session
        return renewal.withLock {
            // Another request may have renewed while this one waited.
            val stored = runCatching { SessionStore.load() }.getOrNull()
            if (!force && stored?.nativeID == id && (stored.expiresAt ?: 0) > soon) return@withLock stored
            val credentials = NativeAuthStore.load()
            if (credentials.cacheID != id) throw NotesException("This connection belongs to another Samsung sign-in. Sign in again.")
            cloudSession(credentials, force).also { SessionStore.save(it) }
        }
    }
}
