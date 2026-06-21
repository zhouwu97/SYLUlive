package com.example.shenliyuan

import android.app.NotificationChannel
import android.app.NotificationManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.zip.Adler32

class MainActivity : FlutterActivity() {

    companion object {
        private const val WIDGET_CHANNEL = "shenliyuan/widget"
        private const val DEEPLINK_CHANNEL = "shenliyuan/deeplink"
        private const val FOREGROUND_CHANNEL = "shenliyuan/foreground"
        private const val KEEP_ALIVE_CHANNEL = "shenliyuan/keep_alive"
        private const val PRIVATE_MESSAGE_NOTIFICATION_CHANNEL =
            "shenliyuan/private_message_notifications"
    }

    private var pendingDeepLink: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createHighPriorityNotificationChannels()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
        pendingDeepLink?.let { link ->
            flutterEngine?.let { engine ->
                MethodChannel(engine.dartExecutor.binaryMessenger, DEEPLINK_CHANNEL)
                    .invokeMethod("onDeepLink", link)
                pendingDeepLink = null
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        handleDeepLink(intent)

        // ── 课程提醒 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CourseReminderLiveScheduler.CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleAndroidLiveReminders" -> {
                    val reminders = call.argument<List<Any?>>("reminders")
                        ?.mapNotNull { (it as? Map<*, *>)?.let(CourseReminderLiveScheduler.LiveReminder::fromMap) }
                        ?: emptyList()
                    val ids = CourseReminderLiveScheduler.schedule(this, reminders)
                    result.success(ids)
                }
                "cancelAndroidLiveReminders" -> {
                    val ids = call.argument<List<Any?>>("ids")
                        ?.mapNotNull { (it as? Number)?.toInt() }
                        ?: emptyList()
                    CourseReminderLiveScheduler.cancel(this, ids)
                    result.success(null)
                }
                "getAndroidBackgroundStatus" -> {
                    result.success(CourseReminderLiveScheduler.backgroundStatus(this))
                }
                "requestAndroidBatteryOptimizationExemption" -> {
                    result.success(CourseReminderLiveScheduler.requestBatteryOptimizationExemption(this))
                }
                "openAndroidBackgroundKeepAliveSettings" -> {
                    result.success(CourseReminderLiveScheduler.openBackgroundKeepAliveSettings(this))
                }
                "openAndroidExactAlarmSettings" -> {
                    result.success(CourseReminderLiveScheduler.openExactAlarmSettings(this))
                }
                else -> result.notImplemented()
            }
        }

        // ── 小组件 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    try {
                        refreshWidgets()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WIDGET_UPDATE_FAILED", e.message, null)
                    }
                }
                "startPeriodicUpdate" -> {
                    WidgetUpdateWorker.enqueue(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── 深度链接 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEPLINK_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingDeepLink" -> {
                    val link = pendingDeepLink
                    pendingDeepLink = null
                    result.success(link)
                }
                else -> result.notImplemented()
            }
        }

        // ── 前台唤醒 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToForeground" -> {
                    try {
                        val intent = packageManager.getLaunchIntentForPackage(packageName)
                        if (intent != null) {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FOREGROUND_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── 私信通知清理 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PRIVATE_MESSAGE_NOTIFICATION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "clearConversationNotifications" -> {
                    val conversationId = call.argument<Number>("conversationId")?.toLong()
                    clearPrivateMessageNotifications(conversationId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── 后台保活 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            KEEP_ALIVE_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getKeepAliveStatus" -> {
                        result.success(KeepAliveForegroundService.status(this))
                    }
                    "setKeepAliveEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        result.success(KeepAliveForegroundService.setEnabled(this, enabled))
                    }
                    "openKeepAliveSettings" -> {
                        result.success(
                            CourseReminderLiveScheduler.openBackgroundKeepAliveSettings(this)
                        )
                    }
                    "syncKeepAliveAuthToken" -> {
                        KeepAliveForegroundService.syncAuthToken(
                            this,
                            call.argument<String>("token")
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("KEEP_ALIVE_FAILED", e.message, null)
            }
        }

        // ── 一次性初始化：启动 WorkManager 定期刷新 ──
        WidgetUpdateWorker.enqueue(this)
    }

    /** 立即刷新所有桌面 widget 实例 */
    private fun refreshWidgets() {
        val appWidgetManager = AppWidgetManager.getInstance(this)
        
        // 刷新课表小组件
        val courseComponent = ComponentName(this, TodayCourseWidgetProvider::class.java)
        val courseIds = appWidgetManager.getAppWidgetIds(courseComponent)
        for (id in courseIds) {
            val views = TodayCourseWidgetProvider.buildRemoteViews(this, id)
            appWidgetManager.updateAppWidget(id, views)
        }
        if (courseIds.isNotEmpty()) {
            appWidgetManager.notifyAppWidgetViewDataChanged(courseIds, R.id.course_list_view)
        }

        // 刷新考试小组件
        val examComponent = ComponentName(this, ExamWidgetProvider::class.java)
        val examIds = appWidgetManager.getAppWidgetIds(examComponent)
        for (id in examIds) {
            val views = ExamWidgetProvider.buildRemoteViews(this, id)
            appWidgetManager.updateAppWidget(id, views)
        }
        if (examIds.isNotEmpty()) {
            appWidgetManager.notifyAppWidgetViewDataChanged(examIds, R.id.exam_list_view)
        }
    }

    private fun handleDeepLink(intent: Intent?) {
        val data = intent?.data
        if (intent?.action == "com.example.shenliyuan.ACTION_WIDGET_TIMETABLE") {
            pendingDeepLink = "widget_timetable"
        } else if (intent?.action == Intent.ACTION_VIEW && data?.toString() == "campus://timetable") {
            pendingDeepLink = "campus://timetable"
        } else if (intent?.action == "com.example.shenliyuan.ACTION_WIDGET_EXAM") {
            val examName = intent.getStringExtra("exam_name") ?: ""
            val examDate = intent.getStringExtra("exam_date") ?: ""
            if (examName.isNotEmpty()) {
                pendingDeepLink = "widget_exam?name=${Uri.encode(examName)}&date=${Uri.encode(examDate)}"
            } else {
                pendingDeepLink = "widget_exam"
            }
        }
    }

    private fun clearPrivateMessageNotifications(conversationId: Long?) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val expectedId = conversationId?.let {
            jpushNotificationId("private_message_conversation_$it")
        }
        if (expectedId != null && expectedId > 0) {
            manager.cancel(expectedId)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        manager.activeNotifications
            ?.filter { it.packageName == packageName }
            ?.filter { isPrivateMessageNotification(it.notification) }
            ?.filter { notification ->
                conversationId == null ||
                    notification.id == expectedId ||
                    notificationMatchesConversation(notification.notification, conversationId)
            }
            ?.forEach { notification ->
                if (notification.tag != null) {
                    manager.cancel(notification.tag, notification.id)
                } else {
                    manager.cancel(notification.id)
                }
            }
    }

    private fun isPrivateMessageNotification(notification: android.app.Notification): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return notification.channelId == "private_messages" ||
                notification.channelId == "private_message_push"
        }
        return true
    }

    private fun notificationMatchesConversation(
        notification: android.app.Notification,
        conversationId: Long
    ): Boolean {
        val extras = notification.extras ?: return false
        val directKeys = listOf(
            "conversation_id",
            "cn.jpush.android.CONVERSATION_ID",
            "cn.jpush.android.EXTRA_CONVERSATION_ID"
        )
        for (key in directKeys) {
            if (extras.get(key)?.toString()?.toLongOrNull() == conversationId) {
                return true
            }
        }

        val jsonKeys = listOf(
            "cn.jpush.android.EXTRA",
            "cn.jpush.android.EXTRA_EXTRA",
            "android.extra.TEXT"
        )
        for (key in jsonKeys) {
            val raw = extras.get(key)?.toString() ?: continue
            try {
                val json = JSONObject(raw)
                if (json.optString("conversation_id").toLongOrNull() == conversationId) {
                    return true
                }
            } catch (_: Exception) {
            }
        }
        return false
    }

    private fun jpushNotificationId(messageId: String): Int {
        if (messageId.isEmpty()) return 0
        messageId.toIntOrNull()?.let { return it }
        val adler32 = Adler32()
        adler32.update(messageId.toByteArray())
        val value = adler32.value.toInt()
        return if (value < 0) kotlin.math.abs(value) else value
    }

    /** 在 JPush SDK 初始化前创建高优先级通知渠道，实现悬浮弹窗 */
    private fun createHighPriorityNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        // 默认渠道：评论/系统通知 → 静默（状态栏折叠，不弹窗）
        manager.createNotificationChannel(
            NotificationChannel(
                "developer-default",
                "通知",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "评论、系统通知等"
            }
        )
        // 私信渠道：悬浮弹窗
        manager.createNotificationChannel(
            NotificationChannel(
                "private_messages",
                "私信通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "收到新的私信时提醒"
                enableVibration(true)
            }
        )
        // 旧版本曾使用 private_message_push；保留渠道，不再作为新私信推送目标。
        manager.createNotificationChannel(
            NotificationChannel(
                "private_message_push",
                "私信通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "兼容旧版本私信通知"
                enableVibration(true)
            }
        )
        KeepAliveForegroundService.ensureChannel(this)
    }
}
