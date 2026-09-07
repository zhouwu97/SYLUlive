package com.example.shenliyuan

import android.content.Context
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

internal object UpdateDownloadScheduler {
    fun enqueue(
        context: Context,
        release: UpdateRelease,
        wifiOnly: Boolean,
        userInitiated: Boolean,
    ) {
        release.validate()
        clearOtherReleases(context, release)
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
                .build())
            .build()
        val existing = UpdateManifestStore.read(context, release)
        if (existing == null) {
            UpdateManifestStore.write(context, UpdateDownloadManifest(release, "queued"))
        } else if (existing.state != "ready") {
            existing.state = "queued"
            existing.errorCode = null
            UpdateManifestStore.write(context, existing)
        }
        WorkManager.getInstance(context).enqueueUniqueWork(
            UpdateDownloadWorker.uniqueName(release.versionCode),
            if (userInitiated) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            request,
        )
    }

    fun cancel(context: Context, release: UpdateRelease, deleteFiles: Boolean = false) {
        WorkManager.getInstance(context).cancelUniqueWork(UpdateDownloadWorker.uniqueName(release.versionCode))
        if (deleteFiles) UpdateManifestStore.delete(context, release)
        else UpdateManifestStore.read(context, release)?.let { manifest ->
            manifest.state = "paused"
            UpdateManifestStore.write(context, manifest)
        }
        UpdateNotificationManager.cancel(context)
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
}
