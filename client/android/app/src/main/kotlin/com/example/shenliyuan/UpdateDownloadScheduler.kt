package com.example.shenliyuan

import android.content.Context
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.UUID

internal object UpdateDownloadScheduler {
    fun enqueue(
        context: Context,
        release: UpdateRelease,
        wifiOnly: Boolean,
        userInitiated: Boolean,
        allowBackground: Boolean,
    ) {
        release.validate()
        clearOtherReleases(context, release)
        val existing = UpdateManifestStore.read(context, release)
        // 自动任务遇到仍在执行的同版本 work 保持原 generation，不能让 KEEP 留下的 Worker 失效。
        if (!userInitiated && existing?.state in ACTIVE_STATES) return
        if (existing?.state == "ready") return
        val workerId = UUID.randomUUID().toString()
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .build()
        val request = OneTimeWorkRequestBuilder<UpdateDownloadWorker>()
            .setConstraints(constraints)
            .setInputData(Data.Builder()
                .putLong(UpdateDownloadWorker.KEY_VERSION_CODE, release.versionCode)
                .putString(UpdateDownloadWorker.KEY_VERSION_NAME, release.versionName)
                .putString(UpdateDownloadWorker.KEY_DOWNLOAD_URL, release.downloadUrl)
                .putLong(UpdateDownloadWorker.KEY_FILE_SIZE, release.fileSize)
                .putString(UpdateDownloadWorker.KEY_SHA256, release.sha256.lowercase())
                .putString(UpdateDownloadWorker.KEY_WORKER_ID, workerId)
                .putBoolean(UpdateDownloadWorker.KEY_ALLOW_BACKGROUND, allowBackground)
                .build())
            .build()
        if (existing == null) {
            UpdateManifestStore.write(context, UpdateDownloadManifest(
                release = release,
                state = "queued",
                wifiOnly = wifiOnly,
                userInitiated = userInitiated,
                allowBackground = allowBackground,
                currentWorkerId = workerId,
            ))
        } else {
            existing.state = "queued"
            existing.errorCode = null
            existing.wifiOnly = wifiOnly
            existing.userInitiated = userInitiated
            existing.allowBackground = allowBackground
            existing.currentWorkerId = workerId
            UpdateManifestStore.write(context, existing)
        }
        WorkManager.getInstance(context).enqueueUniqueWork(
            UpdateDownloadWorker.uniqueName(release.versionCode),
            if (userInitiated) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            request,
        )
    }

    fun cancel(context: Context, release: UpdateRelease, deleteFiles: Boolean = false) {
        if (deleteFiles) UpdateManifestStore.delete(context, release)
        else UpdateManifestStore.read(context, release)?.let { manifest ->
            manifest.state = "paused"
            manifest.currentWorkerId = null
            UpdateManifestStore.write(context, manifest)
        }
        // 先撤销 generation，再请求 WorkManager 停止，旧 Worker 的最后一次进度写入会被拒绝。
        WorkManager.getInstance(context).cancelUniqueWork(UpdateDownloadWorker.uniqueName(release.versionCode))
        UpdateNotificationManager.cancel(context)
    }

    fun pauseDisallowedBackground(context: Context) {
        UpdateManifestStore.rootDirectory(context).listFiles { file -> file.name.endsWith(".manifest.json") }
            ?.forEach { file ->
                val manifest = try { UpdateDownloadManifest.fromJson(org.json.JSONObject(file.readText())) }
                    catch (_: Exception) { null }
                if (manifest != null && !manifest.allowBackground && manifest.state in ACTIVE_STATES) {
                    cancel(context, manifest.release)
                }
            }
    }

    /** 发现新发布时立即撤销旧任务与旧 ready 包，避免错误安装已过期 APK。 */
    fun clearSuperseded(context: Context, current: UpdateRelease) {
        clearOtherReleases(context, current)
    }

    private fun clearOtherReleases(context: Context, current: UpdateRelease) {
        UpdateManifestStore.rootDirectory(context).listFiles { file -> file.name.endsWith(".manifest.json") }
            ?.forEach { file ->
                val old = try { UpdateDownloadManifest.fromJson(org.json.JSONObject(file.readText())).release }
                    catch (_: Exception) { null }
                if (old != null && old.versionCode != current.versionCode) {
                    cancel(context, old, deleteFiles = true)
                }
            }
    }

    private val ACTIVE_STATES = setOf("queued", "downloading", "verifying")
}
