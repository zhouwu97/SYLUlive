package com.example.shenliyuan

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

object GradeReminderScheduler {
    private const val WORK_NAME = "grade_reminder_periodic_check"
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY_RUNTIME_USER_ID = "flutter.grade_reminder_user_id"
    private const val KEY_API_BASE_URL = "flutter.grade_reminder_api_base_url"
    private const val KEY_NOTIFICATION_GRANTED = "flutter.grade_reminder_notification_granted"

    fun syncConfig(
        context: Context,
        userId: String?,
        apiBaseUrl: String?,
        year: String? = null,
        semester: Int? = null,
    ) {
        val editor = prefs(context).edit()
        if (userId.isNullOrBlank()) {
            editor.remove(KEY_RUNTIME_USER_ID)
        } else {
            editor.putString(KEY_RUNTIME_USER_ID, userId)
            if (!apiBaseUrl.isNullOrBlank()) {
                editor.putString(KEY_API_BASE_URL, apiBaseUrl)
            }
            if (!year.isNullOrBlank() && semester != null) {
                editor.putString(yearKey(userId), year)
                editor.putInt(semesterKey(userId), semester)
            }
        }
        editor.apply()
    }

    fun setEnabled(
        context: Context,
        enabled: Boolean,
        userId: String,
        apiBaseUrl: String?,
        year: String,
        semester: Int,
        snapshot: JSONObject?,
        notificationGranted: Boolean,
    ): Map<String, Any?> {
        val appContext = context.applicationContext
        syncConfig(appContext, userId, apiBaseUrl, year, semester)
        val effectiveEnabled = enabled && notificationGranted
        val nextState = when {
            enabled && !notificationGranted -> "need_permission"
            effectiveEnabled -> "ready"
            else -> "off"
        }
        val editor = prefs(appContext).edit()
            .putBoolean(enabledKey(userId), effectiveEnabled)
            .putBoolean(KEY_NOTIFICATION_GRANTED, notificationGranted)
            .putString(stateKey(userId), nextState)
            .remove(needActionKey(userId))

        if (snapshot != null) {
            val parsed = GradeReminderSnapshot.fromJsonObject(snapshot)
            if (parsed != null && parsed.isPendingOnly()) {
                editor.putString(
                    snapshotKey(userId, year, semester),
                    parsed.copy(initialized = false).toJson().toString()
                )
            } else {
                editor.putString(snapshotKey(userId, year, semester), snapshot.toString())
            }
        } else if (enabled) {
            editor.putString(
                snapshotKey(userId, year, semester),
                GradeReminderSnapshot(false, emptyList(), System.currentTimeMillis())
                    .toJson()
                    .toString(),
            )
        }
        editor.apply()

        if (effectiveEnabled) {
            enqueue(appContext)
            DiagnosticLogStore.info(
                appContext,
                source = "成绩提醒",
                type = "开启",
                summary = "成绩更新提醒已开启",
                detail = "userId=$userId year=$year semester=$semester",
            )
        } else {
            WorkManager.getInstance(appContext).cancelUniqueWork(WORK_NAME)
            DiagnosticLogStore.info(
                appContext,
                source = "成绩提醒",
                type = "关闭",
                summary = if (enabled && !notificationGranted) {
                    "成绩提醒未获得通知权限，未开启后台检查"
                } else {
                    "成绩更新提醒已关闭"
                },
                detail = "userId=$userId",
            )
        }
        return status(appContext, userId)
    }

    fun syncBaseline(
        context: Context,
        userId: String,
        year: String,
        semester: Int,
        snapshot: JSONObject,
    ) {
        prefs(context).edit()
            .putString(yearKey(userId), year)
            .putInt(semesterKey(userId), semester)
            .putString(snapshotKey(userId, year, semester), snapshot.toString())
            .putString(stateKey(userId), "ready")
            .apply()
    }

    fun clearForUser(context: Context, userId: String) {
        val p = prefs(context)
        val editor = p.edit()
        p.all.keys
            .filter { key ->
                key == enabledKey(userId) ||
                    key == yearKey(userId) ||
                    key == semesterKey(userId) ||
                    key == lastCheckKey(userId) ||
                    key == lastSuccessKey(userId) ||
                    key == failuresKey(userId) ||
                    key == needActionKey(userId) ||
                    key == stateKey(userId) ||
                    key == needLoginNotifiedKey(userId) ||
                    key == needBindNotifiedKey(userId) ||
                    key.startsWith("flutter.grade_reminder_snapshot_${userId}_") ||
                    key.startsWith("flutter.grade_reminder_notified_hashes_${userId}_")
            }
            .forEach { editor.remove(it) }
        if (p.getString(KEY_RUNTIME_USER_ID, null) == userId) {
            editor.remove(KEY_RUNTIME_USER_ID)
        }
        editor.apply()
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
        DiagnosticLogStore.info(
            context,
            source = "成绩提醒",
            type = "清理",
            summary = "已清理成绩提醒状态",
            detail = "userId=$userId",
        )
    }

    fun clearAllGradeUpdateNotifications(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        
        manager.activeNotifications
            ?.filter { it.packageName == context.packageName }
            ?.filter { it.notification.channelId == GradeReminderWorker.CHANNEL_ID }
            ?.forEach { notification ->
                if (notification.tag != null) {
                    manager.cancel(notification.tag, notification.id)
                } else {
                    manager.cancel(notification.id)
                }
            }
    }

    fun status(context: Context, userIdArg: String?): Map<String, Any?> {
        val p = prefs(context)
        val userId = userIdArg?.takeIf { it.isNotBlank() }
            ?: p.getString(KEY_RUNTIME_USER_ID, null)
        val keepAlive = KeepAliveForegroundService.status(context)
        val notificationGranted = areNotificationsEnabled(context)
        val enabled = userId?.let { p.getBoolean(enabledKey(it), false) } ?: false
        return mapOf(
            "supported" to true,
            "enabled" to enabled,
            "state" to (userId?.let { p.getString(stateKey(it), null) } ?: "off"),
            "notificationGranted" to notificationGranted,
            "backgroundReady" to (keepAlive["isIgnoringBatteryOptimizations"] == true),
            "needAction" to userId?.let { p.getString(needActionKey(it), null) },
            "year" to userId?.let { p.getString(yearKey(it), null) },
            "semester" to userId?.let {
                if (p.contains(semesterKey(it))) p.getInt(semesterKey(it), 0) else null
            },
            "lastCheckAt" to userId?.let { p.getLong(lastCheckKey(it), 0L) },
            "lastSuccessAt" to userId?.let { p.getLong(lastSuccessKey(it), 0L) },
            "consecutiveFailures" to (userId?.let { p.getInt(failuresKey(it), 0) } ?: 0),
        )
    }

    fun openNotificationSettings(activity: Activity): Boolean {
        val intents = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            intents += Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, GradeReminderWorker.CHANNEL_ID)
            }
        }
        intents += Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        }
        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${activity.packageName}")
        }
        return intents.any { startActivitySafely(activity, it) }
    }

    fun enqueue(context: Context) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = PeriodicWorkRequestBuilder<GradeReminderWorker>(
            4, TimeUnit.HOURS,
            1, TimeUnit.HOURS,
        )
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    private val ioExecutor by lazy { Executors.newSingleThreadExecutor() }

    /**
     * Check-then-enqueue：只在成绩提醒已开启、且 WorkManager 没有处于 ENQUEUED/RUNNING 的周期任务时
     * 才补建任务。避免每次调用都 UPDATE 周期任务导致下次执行时间被反复推迟（"永远不到 4 小时"）。
     */
    fun ensureScheduledIfEnabled(context: Context) {
        val appContext = context.applicationContext
        val p = prefs(appContext)
        val userId = runtimeUserId(appContext)
        if (userId.isNullOrBlank()) return
        if (!p.getBoolean(enabledKey(userId), false)) return

        val future = WorkManager.getInstance(appContext)
            .getWorkInfosForUniqueWork(WORK_NAME)
        future.addListener({
            try {
                val infos = future.get()
                val active = infos.any {
                    it.state == WorkInfo.State.ENQUEUED ||
                        it.state == WorkInfo.State.RUNNING
                }
                if (!active) {
                    enqueue(appContext)
                    DiagnosticLogStore.info(
                        appContext,
                        source = "成绩提醒",
                        type = "补建任务",
                        summary = "检测到周期任务缺失，已重新调度",
                        detail = "userId=$userId",
                    )
                }
            } catch (_: Exception) {
                // 查询失败时按"缺失"处理，补建一次
                enqueue(appContext)
            }
        }, ioExecutor)
    }

    /**
     * 立即触发一次成绩检查（OneTimeWorkRequest），用于调试/手动验证后台逻辑。
     * 使用独立的 one-shot 唯一名称，不影响周期任务的调度节奏。
     */
    fun runCheckNow(context: Context) {
        val appContext = context.applicationContext
        val p = prefs(appContext)
        val userId = runtimeUserId(appContext)
        if (userId.isNullOrBlank()) return
        if (!p.getBoolean(enabledKey(userId), false)) return

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = OneTimeWorkRequestBuilder<GradeReminderWorker>()
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(
            "$WORK_NAME-oneshot",
            ExistingWorkPolicy.REPLACE,
            request,
        )
        DiagnosticLogStore.info(
            appContext,
            source = "成绩提醒",
            type = "立即检查",
            summary = "手动触发一次成绩检查",
            detail = "userId=$userId",
        )
    }

    fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun runtimeUserId(context: Context): String? =
        prefs(context).getString(KEY_RUNTIME_USER_ID, null)

    fun apiBaseUrl(context: Context): String? =
        prefs(context).getString(KEY_API_BASE_URL, null)

    fun enabledKey(userId: String) = "flutter.grade_reminder_enabled_$userId"
    fun yearKey(userId: String) = "flutter.grade_reminder_year_$userId"
    fun semesterKey(userId: String) = "flutter.grade_reminder_semester_$userId"
    fun snapshotKey(userId: String, year: String, semester: Int) =
        "flutter.grade_reminder_snapshot_${userId}_${year}_$semester"
    fun hashesKey(userId: String, year: String, semester: Int) =
        "flutter.grade_reminder_notified_hashes_${userId}_${year}_$semester"
    fun lastCheckKey(userId: String) = "flutter.grade_reminder_last_check_at_$userId"
    fun lastSuccessKey(userId: String) = "flutter.grade_reminder_last_success_at_$userId"
    fun failuresKey(userId: String) = "flutter.grade_reminder_consecutive_failures_$userId"
    fun needActionKey(userId: String) = "flutter.grade_reminder_need_action_$userId"
    fun stateKey(userId: String) = "flutter.grade_reminder_state_$userId"
    fun needLoginNotifiedKey(userId: String) =
        "flutter.grade_reminder_need_login_notified_$userId"
    fun needBindNotifiedKey(userId: String) =
        "flutter.grade_reminder_need_bind_notified_$userId"
    fun authTokenKey() = "flutter.keep_alive_auth_token"

    private fun areNotificationsEnabled(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !manager.areNotificationsEnabled()) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = manager.getNotificationChannel(GradeReminderWorker.CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }

    private fun startActivitySafely(activity: Activity, intent: Intent): Boolean {
        return try {
            if (intent.resolveActivity(activity.packageManager) == null) {
                false
            } else {
                activity.startActivity(intent)
                true
            }
        } catch (_: Exception) {
            false
        }
    }
}
