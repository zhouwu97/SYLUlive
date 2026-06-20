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
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            prefs(this).edit().putBoolean(KEY_ENABLED, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }

        prefs(this).edit().putBoolean(KEY_ENABLED, true).apply()
        isRunning = true
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        scheduleHeartbeat(immediate = true)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(heartbeatRunnable)
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

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
            try {
                connection = URL(HEARTBEAT_URL).openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 8000
                connection.readTimeout = 8000
                connection.setRequestProperty("Authorization", "Bearer $token")
                connection.inputStream.use { it.readBytes() }
            } catch (e: Exception) {
                Log.d(TAG, "heartbeat skipped: ${e.message}")
            } finally {
                connection?.disconnect()
            }
        }.start()
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
            prefs(appContext).edit().putBoolean(KEY_ENABLED, enabled).apply()
            if (enabled) {
                start(appContext)
            } else {
                appContext.stopService(Intent(appContext, KeepAliveForegroundService::class.java))
                isRunning = false
            }
            return status(appContext)
        }

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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
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
