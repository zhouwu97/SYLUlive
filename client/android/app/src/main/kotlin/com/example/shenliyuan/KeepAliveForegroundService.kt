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
            DiagnosticLogStore.error(
                this,
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
        DiagnosticLogStore.warning(
            this,
            source = "保活",
            type = "后台任务移除",
            summary = "应用最近任务卡片已被划掉",
            detail = "enabled=${isEnabled(this)}\nserviceRunning=$isRunning\npid=${android.os.Process.myPid()}"
        )
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        DiagnosticLogStore.warning(
            this,
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
                detail = "foreground=${Build.VERSION.SDK_INT >= Build.VERSION_CODES.O}",
            )
            
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                DiagnosticLogStore.error(
                    context,
                    source = "保活",
                    type = e.javaClass.simpleName,
                    summary = "提交保活服务启动请求失败",
                    detail = Log.getStackTraceString(e),
                )
                throw e
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
