package com.example.shenliyuan

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

internal class UpdateDownloadWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        val release = try {
            UpdateRelease(
                versionCode = inputData.getLong(KEY_VERSION_CODE, 0),
                versionName = inputData.getString(KEY_VERSION_NAME).orEmpty(),
                downloadUrl = inputData.getString(KEY_DOWNLOAD_URL).orEmpty(),
                fileSize = inputData.getLong(KEY_FILE_SIZE, 0),
                sha256 = inputData.getString(KEY_SHA256).orEmpty(),
            ).also { it.validate() }
        } catch (_: Exception) {
            return Result.failure()
        }
        val downloader = UpdatePackageDownloader(applicationContext)
        return try {
            val initial = UpdateManifestStore.read(applicationContext, release)
                ?: UpdateDownloadManifest(release, "queued")
            setForeground(UpdateNotificationManager.foregroundInfo(applicationContext, initial))
            downloader.prepare(release) { manifest ->
                UpdateNotificationManager.showProgress(applicationContext, manifest)
            }.also { manifest ->
                UpdateNotificationManager.showReady(applicationContext, manifest)
            }
            Result.success()
        } catch (_: Exception) {
            // 网络中断交给 WorkManager 的网络约束重新调度；manifest 保留断点。
            val state = UpdateManifestStore.read(applicationContext, release)?.state
            if (state == "paused") Result.retry() else Result.failure()
        }
    }

    companion object {
        const val KEY_VERSION_CODE = "versionCode"
        const val KEY_VERSION_NAME = "versionName"
        const val KEY_DOWNLOAD_URL = "downloadUrl"
        const val KEY_FILE_SIZE = "fileSize"
        const val KEY_SHA256 = "sha256"
        fun uniqueName(versionCode: Long) = "app_update_$versionCode"
    }
}
