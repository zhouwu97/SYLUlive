package com.example.shenliyuan

import android.app.NotificationManager
import android.content.Context
import androidx.work.WorkManager

/**
 * 成绩提醒退役迁移器。
 *
 * 新版本不再创建成绩提醒任务，也不把成绩、令牌或教务请求交给 Android
 * 后台组件。每次启动执行一次可重复的清理，覆盖已安装旧版本留下的任务、
 * 通知和 FlutterSharedPreferences 状态。
 */
object GradeReminderScheduler {
    private const val WORK_NAME = "grade_reminder_periodic_check"
    private const val ONESHOT_WORK_NAME = "$WORK_NAME-oneshot"
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val LEGACY_KEY_PREFIX = "flutter.grade_reminder_"
    private const val LEGACY_CHANNEL_ID = "grade_updates"

    fun disableLegacyFeature(context: Context) {
        val appContext = context.applicationContext
        WorkManager.getInstance(appContext).cancelUniqueWork(WORK_NAME)
        WorkManager.getInstance(appContext).cancelUniqueWork(ONESHOT_WORK_NAME)

        val preferences =
            appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        preferences.edit()
            .apply {
                preferences.all.keys
                    .filter { it.startsWith(LEGACY_KEY_PREFIX) }
                    .forEach(::remove)
            }
            .apply()

        val notificationManager =
            appContext.getSystemService(NotificationManager::class.java)
                ?: return
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            notificationManager.activeNotifications
                .filter { it.notification.channelId == LEGACY_CHANNEL_ID }
                .forEach { notification ->
                    notificationManager.cancel(notification.tag, notification.id)
                }
            notificationManager.deleteNotificationChannel(LEGACY_CHANNEL_ID)
        }
    }
}
