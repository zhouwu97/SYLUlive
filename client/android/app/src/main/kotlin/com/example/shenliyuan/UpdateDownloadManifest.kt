package com.example.shenliyuan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

internal data class UpdateRelease(
    val versionCode: Long,
    val versionName: String,
    val downloadUrl: String,
    val fileSize: Long,
    val sha256: String,
) {
    fun validate() {
        require(versionCode > 0) { "versionCode 非法" }
        require(versionName.isNotBlank()) { "versionName 不能为空" }
        require(downloadUrl.startsWith("https://")) { "下载地址必须使用 HTTPS" }
        require(fileSize > 0) { "fileSize 非法" }
        require(sha256.matches(Regex("[0-9a-fA-F]{64}"))) { "sha256 非法" }
    }
}

internal data class UpdateSegment(
    val start: Long,
    val end: Long,
    var downloaded: Long,
)

internal data class UpdateDownloadManifest(
    val release: UpdateRelease,
    var state: String,
    var bytesPerSecond: Long = 0,
    var errorCode: String? = null,
    var apkPath: String? = null,
    // 任务策略随断点持久化，前后台切换后不能擅自改变 WLAN / 移动网络约束。
    var wifiOnly: Boolean = true,
    var userInitiated: Boolean = false,
    val segments: MutableList<UpdateSegment> = mutableListOf(),
) {
    fun receivedBytes(): Long = segments.sumOf { it.downloaded }

    fun toJson(): JSONObject = JSONObject()
        .put("versionCode", release.versionCode)
        .put("versionName", release.versionName)
        .put("downloadUrl", release.downloadUrl)
        .put("fileSize", release.fileSize)
        .put("sha256", release.sha256.lowercase())
        .put("state", state)
        .put("bytesPerSecond", bytesPerSecond)
        .put("errorCode", errorCode)
        .put("apkPath", apkPath)
        .put("wifiOnly", wifiOnly)
        .put("userInitiated", userInitiated)
        .put("segments", JSONArray().apply {
            segments.forEach { segment ->
                put(JSONObject()
                    .put("start", segment.start)
                    .put("end", segment.end)
                    .put("downloaded", segment.downloaded))
            }
        })

    companion object {
        fun fromJson(json: JSONObject): UpdateDownloadManifest {
            val release = UpdateRelease(
                versionCode = json.getLong("versionCode"),
                versionName = json.getString("versionName"),
                downloadUrl = json.getString("downloadUrl"),
                fileSize = json.getLong("fileSize"),
                sha256 = json.getString("sha256"),
            )
            release.validate()
            val segments = mutableListOf<UpdateSegment>()
            val rawSegments = json.optJSONArray("segments") ?: JSONArray()
            for (index in 0 until rawSegments.length()) {
                val segment = rawSegments.getJSONObject(index)
                segments += UpdateSegment(
                    start = segment.getLong("start"),
                    end = segment.getLong("end"),
                    downloaded = segment.getLong("downloaded"),
                )
            }
            return UpdateDownloadManifest(
                release = release,
                state = json.optString("state", "idle"),
                bytesPerSecond = json.optLong("bytesPerSecond", 0),
                errorCode = json.optString("errorCode").takeIf { it.isNotBlank() },
                apkPath = json.optString("apkPath").takeIf { it.isNotBlank() },
                wifiOnly = json.optBoolean("wifiOnly", true),
                userInitiated = json.optBoolean("userInitiated", false),
                segments = segments,
            )
        }
    }
}

/** 使用 tmp + fsync + rename 写 manifest，防止进程被回收时留下半个 JSON。 */
internal object UpdateManifestStore {
    private fun root(context: Context): File = File(context.cacheDir, "app_updates")
    fun rootDirectory(context: Context): File = root(context).apply { mkdirs() }
    fun manifestFile(context: Context, release: UpdateRelease): File =
        File(rootDirectory(context), "${release.sha256.lowercase()}.manifest.json")

    @Synchronized
    fun write(context: Context, manifest: UpdateDownloadManifest) {
        val target = manifestFile(context, manifest.release)
        val temporary = File(target.parentFile, "${target.name}.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(manifest.toJson().toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        if (target.exists() && !target.delete()) error("无法替换旧更新 manifest")
        if (!temporary.renameTo(target)) error("无法原子写入更新 manifest")
    }

    fun read(context: Context, release: UpdateRelease): UpdateDownloadManifest? = try {
        val target = manifestFile(context, release)
        if (!target.isFile) null else UpdateDownloadManifest.fromJson(JSONObject(target.readText()))
            .takeIf { manifest ->
                manifest.release.versionCode == release.versionCode &&
                    manifest.release.fileSize == release.fileSize &&
                    manifest.release.sha256.equals(release.sha256, ignoreCase = true)
            }
    } catch (_: Exception) {
        null
    }

    fun delete(context: Context, release: UpdateRelease) {
        val directory = rootDirectory(context)
        val prefix = release.sha256.lowercase()
        directory.listFiles()?.filter { it.name.startsWith(prefix) }?.forEach { it.delete() }
    }
}
