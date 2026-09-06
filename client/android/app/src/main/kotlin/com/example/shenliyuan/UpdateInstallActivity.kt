package com.example.shenliyuan

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import android.app.Activity
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/** 通知点击后再次验证 ready manifest 与 APK，安装动作始终来自用户点击。 */
class UpdateInstallActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val release = loadRelease() ?: return finish()
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(android.net.Uri.parse("package:$packageName")))
            return finish()
        }
        val manifest = UpdateManifestStore.read(this, release)
        val file = manifest?.apkPath?.let(::File)
        if (manifest?.state != "ready" || file == null || !isSafeAndValid(file, release)) return finish()
        val uri = FileProvider.getUriForFile(this, "$packageName.update.fileprovider", file)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        finish()
    }

    private fun loadRelease(): UpdateRelease? {
        val version = intent.getLongExtra(EXTRA_VERSION_CODE, 0)
        val sha = intent.getStringExtra(EXTRA_SHA256).orEmpty()
        if (version <= 0 || !sha.matches(Regex("[0-9a-fA-F]{64}"))) return null
        val manifestFile = File(cacheDir, "app_updates/${sha.lowercase()}.manifest.json")
        return try {
            UpdateDownloadManifest.fromJson(org.json.JSONObject(manifestFile.readText())).release
                .takeIf { it.versionCode == version && it.sha256.equals(sha, true) }
        } catch (_: Exception) { null }
    }

    private fun isSafeAndValid(file: File, release: UpdateRelease): Boolean = try {
        val root = File(cacheDir, "app_updates").canonicalFile
        val canonical = file.canonicalFile
        canonical.path.startsWith(root.path + File.separator) && canonical.isFile &&
            canonical.name.endsWith(".apk") && canonical.length() == release.fileSize &&
            sha256(canonical).equals(release.sha256, true)
    } catch (_: Exception) { false }

    private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256").also { digest ->
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
    }.digest().joinToString("") { "%02x".format(it) }

    companion object {
        const val EXTRA_VERSION_CODE = "update_version_code"
        const val EXTRA_SHA256 = "update_sha256"
    }
}
