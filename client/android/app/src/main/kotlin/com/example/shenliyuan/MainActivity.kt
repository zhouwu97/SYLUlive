package com.example.shenliyuan

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.ActivityManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import cn.jpush.android.api.JPushInterface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val WIDGET_CHANNEL = "shenliyuan/widget"
        private const val DEEPLINK_CHANNEL = "shenliyuan/deeplink"
        private const val FOREGROUND_CHANNEL = "shenliyuan/foreground"
        private const val KEEP_ALIVE_CHANNEL = "shenliyuan/keep_alive"
        private const val GRADE_REMINDER_CHANNEL = "shenliyuan/grade_reminders"
        private const val PRIVATE_MESSAGE_NOTIFICATION_CHANNEL =
            "shenliyuan/private_message_notifications"
        private const val NOTIFICATION_OPEN_CHANNEL =
            "shenliyuan/notification_open"
        private const val APP_UPDATE_CHANNEL = "shenliyuan/app_update"

        const val ACTION_OPEN_NOTIFICATION =
            "com.example.shenliyuan.OPEN_NOTIFICATION"

        const val EXTRA_NOTIFICATION_OPEN_JSON =
            "notification_open_json"

        // 兼容旧版本创建但尚未点击的私信通知 Intent。
        const val ACTION_OPEN_PRIVATE_MESSAGE =
            "com.example.shenliyuan.OPEN_PRIVATE_MESSAGE"

        const val EXTRA_PRIVATE_MESSAGE_JSON =
            "private_message_json"

        private val activityInstanceLock = Any()
        private var liveActivityCount = 0
    }

    private var pendingDeepLink: String? = null
    
    private var notificationOpenChannel: MethodChannel? = null

    private val keepAliveHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private var keepAliveVerifyPending = false
    private var activityInstanceRegistered = false
    private var appInForeground = false

    private val keepAliveVerifyRunnable = Runnable {
        if (!keepAliveVerifyPending) return@Runnable
        keepAliveVerifyPending = false

        val status = KeepAliveForegroundService.status(this)

        if (status["enabled"] != true) {
            DiagnosticLogStore.info(
                this,
                source = "保活",
                type = "前台自愈验证取消",
                summary = "用户已关闭后台保活，不再验证服务恢复状态",
                detail = "当前状态: $status",
            )
            return@Runnable
        }

        if (status["serviceRunning"] == true) {
            DiagnosticLogStore.info(
                this,
                source = "保活",
                type = "前台自愈成功",
                summary = "前台服务已恢复运行",
                detail = "当前状态: $status",
            )
        } else {
            DiagnosticLogStore.critical(
                this,
                level = "error",
                source = "保活",
                type = "前台自愈失败",
                summary = "恢复服务后仍未运行",
                detail = "当前状态: $status",
            )
        }
    }

    private val keepAliveHealRunnable = Runnable {
        val status = KeepAliveForegroundService.status(this)
        if (status["enabled"] == true && status["serviceRunning"] != true) {
            DiagnosticLogStore.warning(
                this,
                source = "保活",
                type = "前台自愈",
                summary = "检测到保活服务未运行，正在尝试恢复",
                detail = status.entries.joinToString("\n") {
                    "${it.key}=${it.value}"
                },
            )

            try {
                KeepAliveForegroundService.startIfEnabled(this)
                keepAliveVerifyPending = true
                keepAliveHandler.removeCallbacks(keepAliveVerifyRunnable)
                keepAliveHandler.postDelayed(keepAliveVerifyRunnable, 1500L)
            } catch (e: Exception) {
                DiagnosticLogStore.critical(
                    this,
                    level = "error",
                    source = "保活",
                    type = e.javaClass.simpleName,
                    summary = "前台自动恢复保活服务失败",
                    detail = android.util.Log.getStackTraceString(e),
                )
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val hadLiveInstance = synchronized(activityInstanceLock) {
            val existed = liveActivityCount > 0
            liveActivityCount += 1
            activityInstanceRegistered = true
            existed
        }
        recordActivityCreated(savedInstanceState, hadLiveInstance)
        
        handleNotificationOpenIntent(intent)
        handleDeepLink(intent)
        
        createHighPriorityNotificationChannels()
        applyExcludeFromRecents(KeepAliveForegroundService.isHideRecentsEnabled(this))
    }

    override fun onResume() {
        super.onResume()
        appInForeground = true
        PrivateMessageNotificationState.setAppForeground(this, true)
        recordActivityTransition("resume", "应用进入前台")
    }

    override fun onPause() {
        appInForeground = false
        PrivateMessageNotificationState.setAppForeground(this, false)
        recordActivityTransition("pause", "应用离开前台")
        super.onPause()
    }

    override fun onStart() {
        super.onStart()
        keepAliveHandler.removeCallbacks(keepAliveHealRunnable)
        keepAliveHandler.removeCallbacks(keepAliveVerifyRunnable)
        keepAliveVerifyPending = false
        keepAliveHandler.postDelayed(keepAliveHealRunnable, 1500L)
    }

    override fun onStop() {
        keepAliveHandler.removeCallbacks(keepAliveHealRunnable)
        keepAliveHandler.removeCallbacks(keepAliveVerifyRunnable)
        keepAliveVerifyPending = false
        super.onStop()
    }

    override fun onDestroy() {
        keepAliveHandler.removeCallbacksAndMessages(null)
        val remainingInstances = synchronized(activityInstanceLock) {
            if (activityInstanceRegistered) {
                liveActivityCount = (liveActivityCount - 1).coerceAtLeast(0)
                activityInstanceRegistered = false
            }
            liveActivityCount
        }
        DiagnosticLogStore.info(
            this,
            source = "应用",
            type = "Activity 销毁",
            summary = "应用界面生命周期结束",
            detail = "changingConfigurations=$isChangingConfigurations",
            event = DiagnosticLogStore.EventContext(
                eventCode = "activity_destroyed",
                category = "app",
                operation = "destroy",
                result = "success",
                taskId = taskId,
                isForeground = appInForeground,
                metadata = mapOf(
                    "isTaskRoot" to isTaskRoot,
                    "changingConfigurations" to isChangingConfigurations,
                    "remainingInstances" to remainingInstances,
                ),
            ),
        )
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        DiagnosticLogStore.info(
            this,
            source = "应用",
            type = "任务复用",
            summary = "现有应用任务收到新的启动请求",
            detail = "action=${intent.action}\nflags=${intent.flags}",
            event = DiagnosticLogStore.EventContext(
                eventCode = "activity_new_intent",
                category = "app",
                operation = "reuse",
                result = "success",
                taskId = taskId,
                isForeground = appInForeground,
                metadata = mapOf(
                    "action" to intent.action,
                    "flags" to intent.flags,
                    "isTaskRoot" to isTaskRoot,
                ),
            ),
        )
        
        handleNotificationOpenIntent(intent)
        if (handleDeepLink(intent)) dispatchPendingDeepLink()
    }

    override fun onTrimMemory(level: Int) {
        val uiHidden = level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN
        val event = DiagnosticLogStore.EventContext(
            eventCode = if (uiHidden) "app_ui_hidden" else "app_trim_memory",
            category = "app",
            operation = "trim_memory",
            result = if (uiHidden) "success" else "warning",
            taskId = taskId,
            isForeground = appInForeground,
            metadata = mapOf("level" to level),
        )
        if (uiHidden) {
            DiagnosticLogStore.info(
                this,
                source = "应用",
                type = "界面进入后台",
                summary = "系统通知应用界面已不可见",
                detail = "level=$level",
                event = event,
            )
        } else {
            DiagnosticLogStore.warning(
                this,
                source = "应用",
                type = "系统内存回收提示",
                summary = "系统要求应用释放内存",
                detail = "level=$level",
                event = event,
            )
        }
        super.onTrimMemory(level)
    }

    override fun onLowMemory() {
        DiagnosticLogStore.warning(
            this,
            source = "应用",
            type = "系统内存不足",
            summary = "系统报告设备内存紧张",
            event = DiagnosticLogStore.EventContext(
                eventCode = "app_low_memory",
                category = "app",
                operation = "low_memory",
                result = "warning",
                taskId = taskId,
                isForeground = appInForeground,
            ),
        )
        super.onLowMemory()
    }

    /** Flutter 通道就绪后转发链接；由 Dart 明确确认后再清除队列。 */
    private fun dispatchPendingDeepLink() {
        val link = pendingDeepLink ?: return
        flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, DEEPLINK_CHANNEL)
                .invokeMethod("onDeepLink", link)
        }
    }

    private fun handleNotificationOpenIntent(intent: Intent?) {
        when (intent?.action) {
            ACTION_OPEN_NOTIFICATION -> {
                val event = intent.getStringExtra(EXTRA_NOTIFICATION_OPEN_JSON)
                    ?: NotificationOpenStore.peek(this)
                dispatchNotificationOpen(event)
            }
            ACTION_OPEN_PRIVATE_MESSAGE -> {
                val payload = intent.getStringExtra(EXTRA_PRIVATE_MESSAGE_JSON)
                    ?: return
                val event = try {
                    NotificationOpenStore.enqueue(this, JSONObject(payload))
                } catch (_: Exception) {
                    return
                }
                dispatchNotificationOpen(event)
            }
        }
    }

    private fun dispatchNotificationOpen(event: String?) {
        if (event.isNullOrBlank()) return
        notificationOpenChannel?.invokeMethod("onNotificationOpen", event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        notificationOpenChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_OPEN_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingNotificationOpen" -> {
                        result.success(NotificationOpenStore.peek(this))
                    }
                    "ackNotificationOpen" -> {
                        val eventId = call.argument<String>("id")
                        result.success(
                            eventId != null &&
                                NotificationOpenStore.acknowledge(this, eventId),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        }
        dispatchNotificationOpen(NotificationOpenStore.peek(this))

        // 安装器桥接只接受 cache/app_updates 下已校验的 APK，路径校验同时在
        // Flutter 与原生侧执行，避免任意本地文件被 FileProvider 暴露出去。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_UPDATE_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "canInstallPackages" -> {
                        result.success(canInstallPackages())
                    }
                    "openInstallPermissionSettings" -> {
                        result.success(openInstallPermissionSettings())
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val apk = validatedUpdateApk(path)
                        if (apk == null) {
                            result.error("INVALID_APK_PATH", "APK 路径不合法或文件不存在", null)
                            return@setMethodCallHandler
                        }
                        if (!canInstallPackages()) {
                            result.error(
                                "UNKNOWN_SOURCE_NOT_ALLOWED",
                                "请允许本应用安装未知来源应用",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.update.fileprovider",
                            apk,
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            },
                        )
                        result.success(true)
                    }
                    "deleteDownloadedApk" -> {
                        val apk = validatedUpdateApk(call.argument<String>("path"))
                        result.success(apk?.delete() ?: false)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("APP_UPDATE_INSTALLER_FAILED", e.message, null)
            }
        }
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
                "requestPinWidget" -> {
                    val variant = HomeWidgetRegistry.find(
                        call.argument<String>("kind"),
                        call.argument<String>("size"),
                    )
                    if (variant == null) {
                        result.error("INVALID_WIDGET_VARIANT", "未知的小组件类型或尺寸", null)
                    } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(
                            mapOf(
                                "status" to "unsupported",
                                "message" to "当前 Android 版本不支持应用内添加",
                            ),
                        )
                    } else {
                        val manager = AppWidgetManager.getInstance(this)
                        if (!manager.isRequestPinAppWidgetSupported) {
                            result.success(
                                mapOf(
                                    "status" to "unsupported",
                                    "message" to "当前桌面不支持应用内添加",
                                ),
                            )
                        } else {
                            val accepted = manager.requestPinAppWidget(
                                ComponentName(this, variant.providerClass),
                                null,
                                null,
                            )
                            result.success(
                                mapOf(
                                    "status" to if (accepted) "requested" else "rejected",
                                ),
                            )
                        }
                    }
                }
                "getInstalledWidgetCounts" -> {
                    result.success(HomeWidgetRegistry.installedCounts(this))
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
                    result.success(pendingDeepLink)
                }
                "ackPendingDeepLink" -> {
                    val link = call.argument<String>("link")
                    if (link != null && pendingDeepLink == link) {
                        pendingDeepLink = null
                    }
                    result.success(true)
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
                "setCurrentConversation" -> {
                    val conversationId = call.argument<Number>("conversationId")?.toLong()
                    PrivateMessageNotificationState.setCurrentConversationId(
                        this,
                        conversationId,
                    )
                    result.success(true)
                }
                "syncAlias" -> {
                    val userId = call.argument<String>("userId")
                    if (userId.isNullOrBlank()) {
                        result.error("INVALID_ALIAS", "userId 不能为空", null)
                    } else {
                        val synced = KeepAliveForegroundService.syncAlias(this, userId)
                        if (synced) {
                            KeepAliveForegroundService.reconcileAliasState(this)
                        }
                        result.success(synced)
                    }
                }
                "setPushOptIn" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    KeepAliveForegroundService.setPushOptIn(this, enabled)
                    result.success(true)
                }
                "clearAlias" -> {
                    val gen = KeepAliveForegroundService.markAliasPendingDelete(this)
                    try {
                        val sequence = PrivateMessageJPushReceiver.deleteSequence(gen)
                        JPushInterface.deleteAlias(this, sequence)
                    } catch (e: Exception) {
                        PrivateMessageJPushReceiver.scheduleDeleteRetry(
                            applicationContext,
                            gen,
                        )
                        DiagnosticLogStore.warning(
                            applicationContext,
                            source = "推送",
                            type = "Alias 删除异常",
                            summary = "退出时未能发起 Alias 删除，已安排重试",
                            detail = "gen=$gen error=${e.message}",
                        )
                    }
                    result.success(true)
                }
                "getPushDiagnostics" -> {
                    result.success(getPushDiagnostics())
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
                        DiagnosticLogStore.getLogs(
                            this,
                            onSuccess = { logs ->
                                runOnUiThread {
                                    result.success(logs)
                                }
                            },
                            onError = { error ->
                                runOnUiThread {
                                    result.error(
                                        "DIAGNOSTIC_LOG_READ_FAILED",
                                        error.message,
                                        null
                                    )
                                }
                            }
                        )
                    }
                    "clearDiagnosticLogs" -> {
                        DiagnosticLogStore.clearLogs(
                            this,
                            onSuccess = {
                                runOnUiThread {
                                    result.success(true)
                                }
                            },
                            onError = { error ->
                                runOnUiThread {
                                    result.error(
                                        "DIAGNOSTIC_LOG_CLEAR_FAILED",
                                        error.message,
                                        null
                                    )
                                }
                            }
                        )
                    }
                    "writeDiagnosticLog" -> {
                        val level = call.argument<String>("level") ?: "info"
                        val source = call.argument<String>("source") ?: "Flutter"
                        val type = call.argument<String>("type") ?: "日志"
                        val summary = call.argument<String>("summary") ?: ""
                        val detail = call.argument<String>("detail") ?: ""
                        val metadata =
                            (call.argument<Map<*, *>>("metadata") ?: emptyMap<Any, Any>())
                                .entries
                                .associate { (key, value) -> key.toString() to value }
                        val safeLevel =
                            if (level in listOf("info", "warning", "error")) level else "info"
                        
                        DiagnosticLogStore.writeFromFlutter(
                            this,
                            safeLevel,
                            source,
                            type,
                            summary,
                            detail,
                            DiagnosticLogStore.EventContext(
                                eventCode = call.argument<String>("eventCode").orEmpty(),
                                category = call.argument<String>("category") ?: "app",
                                operation = call.argument<String>("operation").orEmpty(),
                                result = call.argument<String>("result").orEmpty(),
                                traceId = call.argument<String>("traceId").orEmpty(),
                                durationMs =
                                    call.argument<Number>("durationMs")?.toLong(),
                                httpStatus =
                                    call.argument<Number>("httpStatus")?.toInt(),
                                retryCount =
                                    call.argument<Number>("retryCount")?.toInt() ?: 0,
                                route = call.argument<String>("route").orEmpty(),
                                taskId = call.argument<Number>("taskId")?.toInt(),
                                isForeground = call.argument<Boolean>("isForeground"),
                                metadata = metadata,
                            ),
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("KEEP_ALIVE_FAILED", e.message, null)
            }
        }

        // ── 成绩更新提醒 MethodChannel ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GRADE_REMINDER_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getGradeReminderStatus" -> {
                        result.success(
                            GradeReminderScheduler.status(
                                this,
                                call.argument<String>("userId"),
                            ),
                        )
                    }
                    "setGradeReminderEnabled" -> {
                        val userId = call.argument<String>("userId")
                        val year = call.argument<String>("year")
                        val semester = call.argument<Number>("semester")?.toInt()
                        if (userId.isNullOrBlank() || year.isNullOrBlank() || semester == null) {
                            result.error("INVALID_ARGUMENT", "userId/year/semester 不能为空", null)
                            return@setMethodCallHandler
                        }
                        val snapshot = call.argument<Map<*, *>>("snapshot")
                            ?.let { JSONObject(it) }
                        result.success(
                            GradeReminderScheduler.setEnabled(
                                this,
                                enabled = call.argument<Boolean>("enabled") == true,
                                userId = userId,
                                apiBaseUrl = call.argument<String>("apiBaseUrl"),
                                year = year,
                                semester = semester,
                                snapshot = snapshot,
                                notificationGranted =
                                    call.argument<Boolean>("notificationGranted") != false,
                            ),
                        )
                    }
                    "syncGradeReminderConfig" -> {
                        GradeReminderScheduler.syncConfig(
                            this,
                            userId = call.argument<String>("userId"),
                            apiBaseUrl = call.argument<String>("apiBaseUrl"),
                            year = call.argument<String>("year"),
                            semester = call.argument<Number>("semester")?.toInt(),
                        )
                        result.success(true)
                    }
                    "syncGradeReminderBaseline" -> {
                        val userId = call.argument<String>("userId")
                        val year = call.argument<String>("year")
                        val semester = call.argument<Number>("semester")?.toInt()
                        val snapshot = call.argument<Map<*, *>>("snapshot")
                            ?.let { JSONObject(it) }
                        if (
                            userId.isNullOrBlank() ||
                            year.isNullOrBlank() ||
                            semester == null ||
                            snapshot == null
                        ) {
                            result.error("INVALID_ARGUMENT", "成绩提醒基线参数不完整", null)
                            return@setMethodCallHandler
                        }
                        GradeReminderScheduler.syncBaseline(
                            this,
                            userId,
                            year,
                            semester,
                            snapshot,
                        )
                        result.success(true)
                    }
                    "clearGradeReminderForUser" -> {
                        val userId = call.argument<String>("userId")
                        if (!userId.isNullOrBlank()) {
                            GradeReminderScheduler.clearForUser(this, userId)
                        }
                        result.success(true)
                    }
                    "clearGradeUpdateNotifications" -> {
                        GradeReminderScheduler.clearAllGradeUpdateNotifications(this)
                        result.success(true)
                    }
                    "openGradeNotificationSettings" -> {
                        result.success(GradeReminderScheduler.openNotificationSettings(this))
                    }
                    "ensureGradeReminderScheduled" -> {
                        GradeReminderScheduler.ensureScheduledIfEnabled(this)
                        result.success(true)
                    }
                    "runGradeReminderCheckNow" -> {
                        GradeReminderScheduler.runCheckNow(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("GRADE_REMINDER_FAILED", e.message, null)
            }
        }

        // ── 一次性初始化：启动 WorkManager 定期刷新 ──
        WidgetUpdateWorker.enqueue(this)
    }

    private fun recordActivityCreated(
        savedInstanceState: Bundle?,
        hadLiveInstance: Boolean,
    ) {
        val launchType = when {
            hadLiveInstance -> "duplicate_instance"
            savedInstanceState != null -> "activity_recreated"
            else -> "cold_start"
        }
        val title = when (launchType) {
            "duplicate_instance" -> "疑似重复 Activity"
            "activity_recreated" -> "Activity 重建"
            else -> "应用冷启动"
        }
        val summary = when (launchType) {
            "duplicate_instance" -> "同一进程中旧界面仍存活时创建了新界面"
            "activity_recreated" -> "系统使用已保存状态重新创建应用界面"
            else -> "应用进程创建了新的主界面"
        }
        val event = DiagnosticLogStore.EventContext(
            eventCode = "activity_created",
            category = "app",
            operation = "create",
            result = if (hadLiveInstance) "warning" else "success",
            taskId = taskId,
            isForeground = false,
            metadata = mapOf(
                "launchType" to launchType,
                "savedInstanceState" to (savedInstanceState != null),
                "intentAction" to intent?.action,
                "intentFlags" to (intent?.flags ?: 0),
                "isTaskRoot" to isTaskRoot,
                "activityInstance" to System.identityHashCode(this),
                "liveActivityCount" to synchronized(activityInstanceLock) {
                    liveActivityCount
                },
            ),
        )
        if (hadLiveInstance) {
            DiagnosticLogStore.warning(
                this,
                source = "应用",
                type = title,
                summary = summary,
                detail = "action=${intent?.action}\nflags=${intent?.flags ?: 0}",
                event = event,
            )
        } else {
            DiagnosticLogStore.info(
                this,
                source = "应用",
                type = title,
                summary = summary,
                detail = "action=${intent?.action}\nflags=${intent?.flags ?: 0}",
                event = event,
            )
        }
    }

    private fun recordActivityTransition(operation: String, summary: String) {
        DiagnosticLogStore.info(
            this,
            source = "应用",
            type = if (operation == "resume") "进入前台" else "进入后台",
            summary = summary,
            event = DiagnosticLogStore.EventContext(
                eventCode = "app_foreground_changed",
                category = "app",
                operation = operation,
                result = "success",
                taskId = taskId,
                isForeground = operation == "resume",
                metadata = mapOf("isTaskRoot" to isTaskRoot),
            ),
        )
    }

    private fun applyExcludeFromRecents(enabled: Boolean): Boolean {
        val result = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            false
        } else {
            val activityManager =
                getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val currentTask = activityManager?.appTasks?.firstOrNull { appTask ->
                appTask.taskInfo.taskId == taskId
            }
            currentTask?.setExcludeFromRecents(enabled)
            currentTask != null
        }

        val event = DiagnosticLogStore.EventContext(
            eventCode = "task_recents_visibility_changed",
            category = "app",
            operation = if (enabled) "hide" else "show",
            result = if (result) "success" else "failure",
            taskId = taskId,
            isForeground = appInForeground,
            metadata = mapOf(
                "enabled" to enabled,
                "isTaskRoot" to isTaskRoot,
            ),
        )
        if (result) {
            DiagnosticLogStore.info(
                this,
                source = "应用",
                type = "最近任务可见性变更",
                summary = if (enabled) "当前任务已从最近任务中隐藏" else "当前任务已恢复到最近任务",
                event = event,
            )
        } else {
            DiagnosticLogStore.warning(
                this,
                source = "应用",
                type = "最近任务可见性变更失败",
                summary = "未找到当前 Android 任务，设置没有生效",
                detail = "taskId=$taskId\nenabled=$enabled",
                event = event,
            )
        }
        return result
    }

    /** 立即刷新所有桌面 widget 实例 */
    private fun refreshWidgets() {
        HomeWidgetRegistry.refreshAll(this)
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ),
        )
        return true
    }

    private fun validatedUpdateApk(rawPath: String?): File? {
        if (rawPath.isNullOrBlank()) return null
        val root = File(cacheDir, "app_updates").canonicalFile
        val apk = File(rawPath).canonicalFile
        if (!apk.path.startsWith(root.path + File.separator)) return null
        if (!apk.isFile || !apk.name.endsWith(".apk", ignoreCase = true)) return null
        return apk
    }

    private fun handleDeepLink(intent: Intent?): Boolean {
        val data = intent?.data
        if (intent?.action == "com.example.shenliyuan.ACTION_WIDGET_TIMETABLE") {
            pendingDeepLink = "widget_timetable"
            return true
        } else if (intent?.action == Intent.ACTION_VIEW && data?.toString() == "campus://timetable") {
            pendingDeepLink = "campus://timetable"
            return true
        } else if (intent?.action == Intent.ACTION_VIEW &&
            data?.scheme == "sylulive" &&
            data.host == "grades") {
            pendingDeepLink = data.toString()
            return true
        } else if (intent?.action == Intent.ACTION_VIEW && isTeamShareLink(data)) {
            pendingDeepLink = data.toString()
            return true
        } else if (intent?.action == "com.example.shenliyuan.ACTION_WIDGET_EXAM") {
            val examName = intent.getStringExtra("exam_name") ?: ""
            val examDate = intent.getStringExtra("exam_date") ?: ""
            if (examName.isNotEmpty()) {
                pendingDeepLink = "widget_exam?name=${Uri.encode(examName)}&date=${Uri.encode(examDate)}"
            } else {
                pendingDeepLink = "widget_exam"
            }
            return true
        }
        return false
    }

    /** 仅转发受清单约束且携带正整数编号的组队链接。 */
    private fun isTeamShareLink(data: Uri?): Boolean {
        if (data == null) return false
        return when {
            data.scheme == "https" &&
                data.host == "sylulive.online" &&
                data.pathSegments.size == 2 &&
                data.pathSegments.firstOrNull() == "team" ->
                data.queryParameterNames.isEmpty() &&
                    data.pathSegments[1].toLongOrNull()?.let { it > 0L } == true
            data.scheme == "sylulive" &&
                data.host == "team" &&
                data.pathSegments.size == 1 ->
                data.pathSegments.single().toLongOrNull()?.let { it > 0L } == true
            else -> false
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



    /** 收集推送诊断信息供 Flutter 设置页展示 */
    private fun getPushDiagnostics(): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>()

        // 未主动启用推送时不读取 RegistrationID。
        val pushEnabled = KeepAliveForegroundService.isPushEnabled(this)
        info["pushEnabled"] = pushEnabled
        val rid = if (pushEnabled) {
            JPushInterface.getRegistrationID(this)
        } else {
            ""
        }
        info["registrationId"] = rid.ifBlank { null }

        // 系统通知总权限
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        info["notificationsEnabled"] = nm.areNotificationsEnabled()

        // 私信通知渠道状态
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = nm.getNotificationChannel("private_messages")
            info["privateMessageChannelExists"] = channel != null
            if (channel != null) {
                info["privateMessageChannelImportance"] = channel.importance
                info["privateMessageChannelBlocked"] =
                    channel.importance == NotificationManager.IMPORTANCE_NONE
            }
        } else {
            info["privateMessageChannelExists"] = true // pre-Oreo no channels
            info["privateMessageChannelImportance"] = -1
            info["privateMessageChannelBlocked"] = false
        }

        // 保活服务存储的 Alias 及其状态
        info["storedAlias"] = KeepAliveForegroundService.getStoredAlias(this)
        info["storedAliasState"] = KeepAliveForegroundService.getAliasState(this)

        return info
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
