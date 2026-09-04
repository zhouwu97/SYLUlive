package com.example.shenliyuan

import android.content.Context
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/** 使用 Android Keystore 加密保活所需的短期会话令牌。 */
object SecureKeepAliveTokenStore {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "com.example.shenliyuan.keep_alive_token"
    private const val SECURE_PREFS = "keep_alive_secure"
    private const val SECURE_TOKEN = "token"
    private const val LEGACY_PREFS = "FlutterSharedPreferences"
    private const val LEGACY_TOKEN = "flutter.keep_alive_auth_token"
    private const val IV_LENGTH = 12

    fun write(context: Context, token: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(token.toByteArray(StandardCharsets.UTF_8))
        val payload = ByteArray(cipher.iv.size + encrypted.size)
        System.arraycopy(cipher.iv, 0, payload, 0, cipher.iv.size)
        System.arraycopy(encrypted, 0, payload, cipher.iv.size, encrypted.size)
        securePrefs(context).edit()
            .putString(SECURE_TOKEN, Base64.encodeToString(payload, Base64.NO_WRAP))
            .apply()
        legacyPrefs(context).edit().remove(LEGACY_TOKEN).apply()
    }

    fun read(context: Context): String? {
        val encoded = securePrefs(context).getString(SECURE_TOKEN, null)
        if (!encoded.isNullOrBlank()) {
            return try {
                decrypt(encoded)
            } catch (error: Exception) {
                securePrefs(context).edit().remove(SECURE_TOKEN).apply()
                null
            }
        }

        // 仅迁移一次旧版明文，成功后立即删除原值。
        val legacy = legacyPrefs(context).getString(LEGACY_TOKEN, null)
        if (legacy.isNullOrBlank()) return null
        return try {
            write(context, legacy)
            legacy
        } catch (_: Exception) {
            null
        }
    }

    fun clear(context: Context) {
        securePrefs(context).edit().remove(SECURE_TOKEN).apply()
        legacyPrefs(context).edit().remove(LEGACY_TOKEN).apply()
    }

    private fun decrypt(encoded: String): String {
        val payload = Base64.decode(encoded, Base64.DEFAULT)
        require(payload.size > IV_LENGTH)
        val iv = payload.copyOfRange(0, IV_LENGTH)
        val ciphertext = payload.copyOfRange(IV_LENGTH, payload.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val existing = store.getKey(KEY_ALIAS, null)
        if (existing is SecretKey) return existing

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun securePrefs(context: Context) =
        context.applicationContext.getSharedPreferences(SECURE_PREFS, Context.MODE_PRIVATE)

    private fun legacyPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
}
