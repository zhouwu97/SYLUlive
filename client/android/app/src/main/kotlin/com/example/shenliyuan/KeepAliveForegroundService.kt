package com.example.shenliyuan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import cn.jpush.android.api.JPushInterface
import java.net.HttpURLConnection
import java.net.URL

class KeepAliveForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val heartbeatRunnable = Runnable {
        performHeartbeat()
        scheduleHeartbeat(immediate = false)
    }

    override fun onCreate() {
        super.onCreate()
        DiagnosticLogStore.info(
            this,
            source = "保活",
            type = "服务创建",
            summary = "后台保活服务进程已创建",
            detail = "pid=${android.os.Process.myPid()}"
        )
        ensureChannel(this)
        restoreJPush()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            prefs(this).edit().putBoolean(KEY_ENABLED, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }

        val systemRestart = intent == null
        DiagnosticLogStore.info(
            this,
            source = "保活",
            type = if (systemRestart) "系统无 Intent 重建" else "服务启动",
            summary = if (systemRestart) "系统通过 START_STICKY 重新拉起保活服务" else "收到保活服务启动请求",
            detail = "action=${intent?.action ?: "null"}\nflags=$flags\nstartId=$startId\nenabled=${isEnabled(this)}\npid=${android.os.Process.myPid()}\nbatteryOptimized=${!isIgnoringBatteryOptimizations(this)}"
        )

        if (!isEnabled(this)) {
            DiagnosticLogStore.warning(
                this,
                source = "保活",
                type = "无效启动请求",
                summary = "收到服务启动请求，但用户保活开关已关闭",
            )
            isRunning = false
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildNotification()
        
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            DiagnosticLogStore.info(
                this,
                source = "保活",
                type = "前台运行",
                summary = "前台保活通知已建立",
            )
            isRunning = true
        } catch (e: Exception) {
            DiagnosticLogStore.critical(
                this,
                level = "error",
                source = "保活",
                type = e.javaClass.simpleName,
                summary = "前台保活通知建立失败",
                detail = Log.getStackTraceString(e),
            )
            throw e
        }
        
        scheduleHeartbeat(immediate = true)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        DiagnosticLogStore.critical(
            this,
            level = "warning",
            source = "保活",
            type = "后台任务移除",
            summary = "应用最近任务卡片已被划掉",
            detail = "enabled=${isEnabled(this)}\nserviceRunning=$isRunning\npid=${android.os.Process.myPid()}"
        )
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        DiagnosticLogStore.critical(
            this,
            level = "warning",
            source = "保活",
            type = "服务销毁",
            summary = "后台保活服务生命周期结束",
            detail = "enabled=${isEnabled(this)}\nserviceRunning=$isRunning\npid=${android.os.Process.myPid()}"
        )
        handler.removeCallbacks(heartbeatRunnable)
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * 系统通过 START_STICKY 重新拉起保活服务时，Flutter 进程可能已被杀死，
     * 极光长连接和别名注册随之丢失。在此重新初始化极光 SDK，恢复推送能力。
     */
    private fun restoreJPush() {
        // 没登录时不启动推送，维持"登录后才初始化"的逻辑
        if (authToken(this).isNullOrBlank()) {
            Log.d(TAG, "skip JPush restore: user not logged in")
            return
        }

        try {
            // Flutter 进程已被清理时，重新启动极光服务
            JPushInterface.init(applicationContext)
            JPushInterface.resumePush(applicationContext)

            handler.postDelayed({
                val rid = JPushInterface.getRegistrationID(applicationContext)
                val safeRid = if (rid.isNotBlank()) {
                    "***${rid.takeLast(6)}"
                } else {
                    "empty"
                }

                if (rid.isBlank()) {
                    Log.w(TAG, "JPush initialized but registrationId is empty")

                    DiagnosticLogStore.warning(
                        applicationContext,
                        source = "推送",
                        type = "JPush 未注册",
                        summary = "极光推送已初始化，但 RegistrationID 为空",
                    )
                } else {
                    Log.i(TAG, "JPush restored, registrationId=$safeRid")

                    DiagnosticLogStore.info(
                        applicationContext,
                        source = "推送",
                        type = "JPush 恢复",
                        summary = "极光推送连接已恢复",
                        detail = "registrationId=$safeRid",
                    )

                    // 检查 Alias 状态，决定恢复还是重试删除
                    val aliasState = getAliasState(applicationContext)
                    when (aliasState) {
                        "pending_delete" -> {
                            // 之前的删除未完成，重试
                            val alias = getStoredAlias(applicationContext)
                            if (!alias.isNullOrBlank()) {
                                val gen = getAliasGeneration(applicationContext)
                                PrivateMessageJPushReceiver.pendingDeleteGeneration = gen
                                JPushInterface.deleteAlias(
                                    applicationContext,
                                    PrivateMessageJPushReceiver.SEQ_ALIAS_DELETE,
                                )
                                Log.i(TAG, "retry pending alias delete: ***${alias.takeLast(4)} gen=$gen")
                                DiagnosticLogStore.info(
                                    applicationContext,
                                    source = "推送",
                                    type = "Alias 删除重试",
                                    summary = "保活恢复时重试待删除 Alias",
                                    detail = "alias=***${alias.takeLast(4)} gen=$gen",
                                )
                            }
                            return@postDelayed
                        }
                        "active" -> {
                            // 正常恢复
                        }
                        else -> {
                            Log.d(TAG, "skip alias restore: state=$aliasState")
                            return@postDelayed
                        }
                    }
                    val alias = getStoredAlias(applicationContext)
                    if (!alias.isNullOrBlank()) {
                        try {
                            JPushInterface.setAlias(
                                applicationContext,
                                PrivateMessageJPushReceiver.SEQ_ALIAS_RESTORE,
                                alias
                            )
                            Log.i(TAG, "JPush alias restore requested: ***${alias.takeLast(4)}")
                            DiagnosticLogStore.info(
                                applicationContext,
                                source = "推送",
                                type = "Alias 恢复请求",
                                summary = "保活服务已发起 Alias 恢复请求",
                                detail = "alias=***${alias.takeLast(4)} rid=$safeRid",
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "restore alias failed", e)
                            DiagnosticLogStore.warning(
                                applicationContext,
                                source = "推送",
                                type = "Alias 恢复异常",
                                summary = "保活服务恢复 Alias 失败",
                                detail = Log.getStackTraceString(e),
                            )
                        }
                    } else {
                        Log.d(TAG, "no alias stored, skip alias restore")
                    }
                }
            }, 3000L)
        } catch (e: Exception) {
            Log.e(TAG, "restore JPush failed", e)
            DiagnosticLogStore.error(
                applicationContext,
                source = "推送",
                type = "JPush 恢复异常",
                summary = "恢复极光推送服务失败",
                detail = Log.getStackTraceString(e)
            )
        }
    }

    private fun scheduleHeartbeat(immediate: Boolean) {
        handler.removeCallbacks(heartbeatRunnable)
        if (!isEnabled(this)) {
            stopSelf()
            return
        }
        handler.postDelayed(
            heartbeatRunnable,
            if (immediate) INITIAL_HEARTBEAT_DELAY_MS else HEARTBEAT_INTERVAL_MS,
        )
    }

    private fun performHeartbeat() {
        val token = authToken(this)
        if (token.isNullOrBlank()) return

        Thread {
            var connection: HttpURLConnection? = null
            var success = false
            var detailMsg = ""
            try {
                connection = URL(HEARTBEAT_URL).openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 8000
                connection.readTimeout = 8000
                connection.setRequestProperty("Authorization", "Bearer $token")
                val code = connection.responseCode
                success = code in 200..299
                detailMsg = "HTTP $code"
                if (success) {
                    connection.inputStream.use { it.readBytes() }
                } else {
                    connection.errorStream?.use { it.readBytes() }
                }
            } catch (e: Exception) {
                success = false
                detailMsg = e.javaClass.simpleName + ": " + e.message
                Log.d(TAG, "heartbeat skipped: ${e.message}")
            } finally {
                connection?.disconnect()
                reportHeartbeat(success, detailMsg)
            }
        }.start()
    }

    private var lastHeartbeatHealthy: Boolean? = null
    private var lastHeartbeatFailure: String? = null

    private fun reportHeartbeat(success: Boolean, detail: String) {
        val previousHealthy = lastHeartbeatHealthy
        val previousFailure = lastHeartbeatFailure

        lastHeartbeatHealthy = success

        if (!success) {
            val reasonChanged = previousFailure != detail
            lastHeartbeatFailure = detail

            if (previousHealthy != false || reasonChanged) {
                DiagnosticLogStore.warning(
                    this,
                    source = "保活",
                    type = "心跳异常",
                    summary = if (reasonChanged && previousHealthy == false) {
                        "后台心跳失败原因发生变化"
                    } else {
                        "后台心跳请求失败"
                    },
                    detail = detail,
                )
            }
            return
        }

        lastHeartbeatFailure = null

        if (previousHealthy == false) {
            DiagnosticLogStore.info(
                this,
                source = "保活",
                type = "心跳恢复",
                summary = "后台心跳已恢复正常",
                detail = detail,
            )
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag(),
            )
        }
        val stopIntent = Intent(this, KeepAliveForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag(),
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("沈理校园保活中")
            .setContentText("保持私信和课程提醒更稳定")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "关闭", stopPendingIntent)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "keep_alive"
        private const val CHANNEL_NAME = "后台保活"
        private const val TAG = "KeepAliveService"
        private const val NOTIFICATION_ID = 41002
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_ENABLED = "flutter.keep_alive_enabled"
        private const val KEY_HIDE_RECENTS = "flutter.hide_recents_enabled"
        private const val KEY_AUTH_TOKEN = "flutter.keep_alive_auth_token"
        private const val KEY_JPUSH_ALIAS = "flutter.jpush_alias"
        private const val KEY_JPUSH_ALIAS_STATE = "flutter.jpush_alias_state"
        private const val KEY_JPUSH_ALIAS_GEN = "flutter.jpush_alias_generation"
        private const val ACTION_START =
            "com.example.shenliyuan.action.START_KEEP_ALIVE"
        private const val ACTION_STOP =
            "com.example.shenliyuan.action.STOP_KEEP_ALIVE"
        private const val HEARTBEAT_URL =
            "http://156.233.229.232:8080/api/user/notifications/unread_count"
        private const val INITIAL_HEARTBEAT_DELAY_MS = 5_000L
        private const val HEARTBEAT_INTERVAL_MS = 15 * 60 * 1000L

        @Volatile
        private var isRunning = false

        fun setEnabled(context: Context, enabled: Boolean): Map<String, Any> {
            val appContext = context.applicationContext
            DiagnosticLogStore.info(
                appContext,
                source = "保活",
                type = "用户操作",
                summary = if (enabled) "用户开启了后台保活" else "用户关闭了后台保活",
            )
            prefs(appContext).edit().putBoolean(KEY_ENABLED, enabled).apply()
            if (enabled) {
                start(appContext)
            } else {
                appContext.stopService(Intent(appContext, KeepAliveForegroundService::class.java))
                isRunning = false
            }
            return status(appContext)
        }

        fun setHideRecentsEnabled(context: Context, enabled: Boolean) {
            prefs(context.applicationContext)
                .edit()
                .putBoolean(KEY_HIDE_RECENTS, enabled)
                .apply()
        }

        fun isHideRecentsEnabled(context: Context): Boolean =
            prefs(context.applicationContext).getBoolean(KEY_HIDE_RECENTS, false)

        fun startIfEnabled(context: Context) {
            val appContext = context.applicationContext
            if (isEnabled(appContext)) {
                start(appContext)
            }
        }

        fun syncAuthToken(context: Context, token: String?) {
            val editor = prefs(context.applicationContext).edit()
            if (token.isNullOrBlank()) {
                editor.remove(KEY_AUTH_TOKEN)
            } else {
                editor.putString(KEY_AUTH_TOKEN, token)
            }
            editor.apply()
        }

        fun syncAlias(context: Context, alias: String?) {
            val p = prefs(context.applicationContext)
            val editor = p.edit()
            if (alias.isNullOrBlank()) {
                editor.remove(KEY_JPUSH_ALIAS)
                editor.remove(KEY_JPUSH_ALIAS_STATE)
                editor.remove(KEY_JPUSH_ALIAS_GEN)
            } else {
                val gen = p.getInt(KEY_JPUSH_ALIAS_GEN, 0) + 1
                editor.putString(KEY_JPUSH_ALIAS, alias)
                editor.putString(KEY_JPUSH_ALIAS_STATE, "active")
                editor.putInt(KEY_JPUSH_ALIAS_GEN, gen)
                Log.d(TAG, "JPush alias synced: ***${alias.takeLast(4)} state=active gen=$gen")
            }
            editor.apply()
        }

        fun getStoredAlias(context: Context): String? {
            return prefs(context.applicationContext)
                .getString(KEY_JPUSH_ALIAS, null)
        }

        fun getAliasState(context: Context): String? {
            return prefs(context.applicationContext)
                .getString(KEY_JPUSH_ALIAS_STATE, null)
        }

        fun getAliasGeneration(context: Context): Int {
            return prefs(context.applicationContext)
                .getInt(KEY_JPUSH_ALIAS_GEN, 0)
        }

        /** 标记 Alias 为待删除（退出时调用，不等异步回调） */
        fun markAliasPendingDelete(context: Context): Int {
            val p = prefs(context.applicationContext)
            val gen = p.getInt(KEY_JPUSH_ALIAS_GEN, 0) + 1
            p.edit()
                .putString(KEY_JPUSH_ALIAS_STATE, "pending_delete")
                .putInt(KEY_JPUSH_ALIAS_GEN, gen)
                .apply()
            Log.d(TAG, "JPush alias marked pending_delete gen=$gen")
            return gen
        }

        /** 删除回调确认成功后清除（需校验 generation） */
        fun clearStoredAliasIfGeneration(
            context: Context,
            expectedGeneration: Int,
        ): Boolean {
            val p = prefs(context.applicationContext)
            val currentGen = p.getInt(KEY_JPUSH_ALIAS_GEN, 0)
            if (currentGen != expectedGeneration) {
                Log.w(TAG,
                    "skip alias clear: gen mismatch expected=$expectedGeneration actual=$currentGen")
                return false
            }
            p.edit()
                .remove(KEY_JPUSH_ALIAS)
                .remove(KEY_JPUSH_ALIAS_STATE)
                .remove(KEY_JPUSH_ALIAS_GEN)
                .apply()
            Log.d(TAG, "JPush alias cleared gen=$expectedGeneration")
            return true
        }

        /** 无条件清除（仅用于 SDK 未初始化等极端降级） */
        fun clearStoredAlias(context: Context) {
            prefs(context.applicationContext)
                .edit()
                .remove(KEY_JPUSH_ALIAS)
                .remove(KEY_JPUSH_ALIAS_STATE)
                .remove(KEY_JPUSH_ALIAS_GEN)
                .apply()
            Log.d(TAG, "JPush alias cleared (forced)")
        }

        fun status(context: Context): Map<String, Any> {
            val appContext = context.applicationContext
            return mapOf(
                "supported" to true,
                "enabled" to isEnabled(appContext),
                "serviceRunning" to isRunning,
                "hideRecentsEnabled" to isHideRecentsEnabled(appContext),
                "manufacturer" to Build.MANUFACTURER.orEmpty(),
                "sdkInt" to Build.VERSION.SDK_INT,
                "isIgnoringBatteryOptimizations" to
                    isIgnoringBatteryOptimizations(appContext),
            )
        }

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "用于维持私信与课程提醒后台连接"
                    setShowBadge(false)
                },
            )
        }

        private fun start(context: Context) {
            val intent = Intent(context, KeepAliveForegroundService::class.java).apply {
                action = ACTION_START
            }
            
            DiagnosticLogStore.info(
                context,
                source = "保活",
                type = "启动请求",
                summary = "准备启动后台保活服务",
            )
            
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                DiagnosticLogStore.critical(
                    context,
                    level = "error",
                    source = "保活",
                    type = e.javaClass.simpleName,
                    summary = "请求启动前台服务被系统拒绝",
                    detail = Log.getStackTraceString(e),
                )
            }
        }

        private fun prefs(context: Context) =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        private fun isEnabled(context: Context): Boolean =
            prefs(context).getBoolean(KEY_ENABLED, false)

        private fun authToken(context: Context): String? =
            prefs(context).getString(KEY_AUTH_TOKEN, null)

        private fun immutableFlag(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }

        private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            return powerManager.isIgnoringBatteryOptimizations(context.packageName)
        }
    }
}
