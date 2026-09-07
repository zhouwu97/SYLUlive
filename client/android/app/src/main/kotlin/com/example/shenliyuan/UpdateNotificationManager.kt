package com.example.shenliyuan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat

internal object UpdateNotificationManager {
    private const val CHANNEL_ID = "app_update_download"
    // WorkManager 会在 Worker 结束时清理前台通知，完成通知必须使用独立 ID 才能保留安装入口。
    private const val FOREGROUND_NOTIFICATION_ID = 41031
    private const val READY_NOTIFICATION_ID = 41032

    fun foregroundInfo(context: Context, manifest: UpdateDownloadManifest): androidx.work.ForegroundInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            androidx.work.ForegroundInfo(
                FOREGROUND_NOTIFICATION_ID,
                progressNotification(context, manifest),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            androidx.work.ForegroundInfo(FOREGROUND_NOTIFICATION_ID, progressNotification(context, manifest))
        }

    fun showProgress(context: Context, manifest: UpdateDownloadManifest) {
        notificationManager(context).notify(FOREGROUND_NOTIFICATION_ID, progressNotification(context, manifest))
    }

    fun showReady(context: Context, manifest: UpdateDownloadManifest) {
        ensureChannel(context)
        val install = PendingIntent.getActivity(
            context,
            manifest.release.versionCode.toInt(),
            Intent(context, UpdateInstallActivity::class.java)
                .putExtra(UpdateInstallActivity.EXTRA_VERSION_CODE, manifest.release.versionCode)
                .putExtra(UpdateInstallActivity.EXTRA_SHA256, manifest.release.sha256),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        notificationManager(context).notify(
            READY_NOTIFICATION_ID,
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("沈理校园 ${manifest.release.versionName} 已准备完成")
                .setContentText("更新包已经下载并校验完成，点击安装")
                .setContentIntent(install)
                .setAutoCancel(false)
                .setOngoing(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build(),
        )
    }

    fun cancel(context: Context) {
        notificationManager(context).cancel(FOREGROUND_NOTIFICATION_ID)
        notificationManager(context).cancel(READY_NOTIFICATION_ID)
    }

    private fun progressNotification(context: Context, manifest: UpdateDownloadManifest): Notification {
        ensureChannel(context)
        val received = if (manifest.state == "ready") manifest.release.fileSize else manifest.receivedBytes()
        val total = manifest.release.fileSize.coerceAtLeast(1)
        val speed = manifest.bytesPerSecond
        val content = "${formatBytes(received)} / ${formatBytes(total)}" +
            if (speed > 0) " · ${formatBytes(speed)}/s" else ""
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("沈理校园 ${manifest.release.versionName}")
            .setContentText(if (manifest.state == "verifying") "正在校验更新包" else "正在后台下载 · $content")
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setProgress(100, ((received * 100) / total).toInt(), false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        notificationManager(context).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "应用更新", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            },
        )
    }

    private fun notificationManager(context: Context): NotificationManager =
        context.getSystemService(NotificationManager::class.java)

    private fun formatBytes(bytes: Long): String = when {
        bytes >= 1024L * 1024 -> "%.1f MB".format(bytes / 1024.0 / 1024.0)
        else -> "${bytes / 1024} KB"
    }
}
