package com.example.shenliyuan

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.ActivityManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    companion object {
        private const val WIDGET_CHANNEL = "shenliyuan/widget"
        private const val DEEPLINK_CHANNEL = "shenliyuan/deeplink"
        private const val FOREGROUND_CHANNEL = "shenliyuan/foreground"
        private const val KEEP_ALIVE_CHANNEL = "shenliyuan/keep_alive"
        private const val PRIVATE_MESSAGE_NOTIFICATION_CHANNEL =
            "shenliyuan/private_message_notifications"

        const val ACTION_OPEN_PRIVATE_MESSAGE =
            "com.example.shenliyuan.OPEN_PRIVATE_MESSAGE"

        const val EXTRA_PRIVATE_MESSAGE_JSON =
            "private_message_json"
    }

    private var pendingDeepLink: String? = null
    
    private val pendingLock = Any()
    private var pendingPrivateMessageJson: String? = null

    private fun consumePendingPrivateMessage(): String? =
        synchronized(pendingLock) {
            pendingPrivateMessageJson.also {
                pendingPrivateMessageJson = null
            }
        }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        
        handlePrivateMessageIntent(intent)
        
        createHighPriorityNotificationChannels()
        applyExcludeFromRecents(KeepAliveForegroundService.isHideRecentsEnabled(this))

        checkKeepAliveDetached()
    }

    private fun checkKeepAliveDetached() {
        val first = KeepAliveForegroundService.status(this)
        if (first["enabled"] != true || first["serviceRunning"] == true) return

        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            val second = KeepAliveForegroundService.status(this)

            if (second["enabled"] == true &&
                second["serviceRunning"] != true
            ) {
                DiagnosticLogStore.warning(
                    this,
                    source = "保活",
                    type = "疑似状态脱节",
                    summary = "连续两次检测到保活开关已开启，但服务未运行",
                    detail = "first=$first\nsecond=$second",
                )
            }
        }, 1500L)
    }

    override fun onResume() {
        super.onResume()
        PrivateMessageNotificationState.setAppForeground(this, true)
    }

    override fun onPause() {
        PrivateMessageNotificationState.setAppForeground(this, false)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        
        handlePrivateMessageIntent(intent)
        handleDeepLink(intent)
        
        pendingDeepLink?.let { link ->
            flutterEngine?.let { engine ->
                MethodChannel(engine.dartExecutor.binaryMessenger, DEEPLINK_CHANNEL)
                    .invokeMethod("onDeepLink", link)
                pendingDeepLink = null
            }
        }
    }

    private fun handlePrivateMessageIntent(intent: Intent?) {
        if (intent?.action != ACTION_OPEN_PRIVATE_MESSAGE) {
            return
        }

        synchronized(pendingLock) {
            pendingPrivateMessageJson =
                intent.getStringExtra(EXTRA_PRIVATE_MESSAGE_JSON)
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
                "getPendingPrivateMessage" -> {
                    result.success(consumePendingPrivateMessage())
                }
                "clearConversationNotifications" -> {
                    val conversationId = call.argument<Number>("conversationId")?.toLong()
                    clearPrivateMessageNotifications(conversationId)
                    result.success(true)
                }
                "setCurrentConversation" -> {
                    val conversationId = call.argument<Number>("conversationId")?.toLong()
                    PrivateMessageNotificationState.setCurrentConversationId(
                        this,
                        conversationId,
                    )
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
                    "setHideRecentsEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        KeepAliveForegroundService.setHideRecentsEnabled(this, enabled)
                        applyExcludeFromRecents(enabled)
                        result.success(KeepAliveForegroundService.status(this))
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
                    "getDiagnosticLogs" -> {
                        DiagnosticLogStore.getLogs(this) { logs ->
                            runOnUiThread {
                                result.success(logs)
                            }
                        }
                    }
                    "clearDiagnosticLogs" -> {
                        DiagnosticLogStore.clearLogs(this) {
                            runOnUiThread {
                                result.success(true)
                            }
                        }
                    }
                    "writeDiagnosticLog" -> {
                        val level = call.argument<String>("level") ?: "info"
                        val source = call.argument<String>("source") ?: "Flutter"
                        val type = call.argument<String>("type") ?: "日志"
                        val summary = call.argument<String>("summary") ?: ""
                        val detail = call.argument<String>("detail") ?: ""
                        
                        val safeLevel = if (level in listOf("info", "warning", "error")) level else "info"
                        
                        DiagnosticLogStore.writeFromFlutter(
                            this,
                            safeLevel,
                            source,
                            type,
                            summary,
                            detail
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

    private fun applyExcludeFromRecents(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        activityManager?.appTasks?.forEach { task ->
            task.setExcludeFromRecents(enabled)
        }
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
        if (conversationId != null) {
            PrivateMessageNotificationStore.clear(
                this,
                conversationId,
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return

        val manager = getSystemService(NotificationManager::class.java) ?: return

        manager.activeNotifications
            ?.filter { it.packageName == packageName }
            ?.filter { isPrivateMessageNotification(it.notification) }
            ?.filter { notification ->
                conversationId == null ||
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
