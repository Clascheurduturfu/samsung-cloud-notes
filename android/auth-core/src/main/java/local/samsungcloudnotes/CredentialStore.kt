package local.samsungcloudnotes

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/**
 * Credentials are sealed with a non-exportable AES-GCM key in Android Keystore
 * and kept in no-backup app storage, so they never leave this device.
 */
object CredentialVault {
    private const val KEY_ALIAS = "local.samsung-cloud-notes.credentials"
    private val services = setOf("local.samsung-cloud-notes.session", "local.samsung-cloud-notes.native-auth")
    lateinit var directory: File

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return generator.generateKey()
    }
    private fun file(service: String): File {
        require(service in services) { "Unknown credential service." }
        return File(directory, "$service.bin")
    }
    @Synchronized fun save(service: String, plain: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.doFinal(plain.toByteArray())
        directory.mkdirs()
        val target = file(service)
        val temporary = File(directory, target.name + ".tmp")
        temporary.writeBytes(byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + sealed)
        if (!temporary.renameTo(target)) throw NotesException("Could not store the Samsung connection.")
    }
    @Synchronized fun load(service: String): String? {
        val target = file(service)
        if (!target.exists()) return null
        val data = target.readBytes()
        val length = data.firstOrNull()?.toInt() ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 1, length))
            String(cipher.doFinal(data, 1 + length, data.size - 1 - length))
        } catch (_: Exception) {
            throw NotesException("The saved Samsung connection could not be unlocked. Sign in with Samsung again.")
        }
    }
    @Synchronized fun delete(service: String) { file(service).delete() }
}

object SessionStore {
    private const val SERVICE = "local.samsung-cloud-notes.session"
    fun save(value: AccountSession) {
        if (!value.authorization.startsWith("Bearer ") || value.authorization.length <= 30 || value.authorization.any { it == '\n' || it == '\r' }) {
            throw NotesException("This connection does not contain a valid Samsung session.")
        }
        CredentialVault.save(SERVICE, value.toJson())
    }
    fun loadOrNull(): AccountSession? = CredentialVault.load(SERVICE)?.let(AccountSession::fromJson)
    fun load(): AccountSession = loadOrNull() ?: throw NotesException("Sign in with Samsung to get started.")
    fun delete() = CredentialVault.delete(SERVICE)
}

object NativeAuthStore {
    private const val SERVICE = "local.samsung-cloud-notes.native-auth"
    fun save(value: NativeCredentials) = CredentialVault.save(SERVICE, value.toJson())
    fun loadOrNull(): NativeCredentials? = CredentialVault.load(SERVICE)?.let(NativeCredentials::fromJson)
    fun load(): NativeCredentials = loadOrNull() ?: throw NotesException("Sign in with Samsung to get started.")
    fun delete() = CredentialVault.delete(SERVICE)
}
