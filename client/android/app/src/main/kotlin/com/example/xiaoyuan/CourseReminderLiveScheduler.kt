package com.example.shenliyuan

import android.app.AlarmManager
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

object CourseReminderLiveScheduler {
    const val CHANNEL = "shenliyuan/course_reminders"
    private const val ACTION_DISMISS_REMINDER =
        "com.example.shenliyuan.action.DISMISS_COURSE_REMINDER"

    private const val NOTIFICATION_CHANNEL_ID = "course_reminders_silent"
    private const val NOTIFICATION_CHANNEL_NAME = "课程提醒"
    private const val PREFS_NAME = "course_reminder_live_reminders"
    private const val PREFS_REMINDERS = "reminders"
    private const val EXTRA_ID = "id"
    private const val EXTRA_TIME_MILLIS = "timeMillis"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_BODY = "body"
    private const val EXTRA_DETAIL_TEXT = "detailText"
    private const val EXTRA_TICKER = "ticker"
    private const val EXTRA_SHORT_TEXT = "shortText"
    private const val EXTRA_CLASS_START_MILLIS = "classStartMillis"

    data class LiveReminder(
        val id: Int,
        val timeMillis: Long,
        val title: String,
        val body: String,
        val detailText: String,
        val ticker: String,
        val shortText: String,
        val classStartMillis: Long,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put(EXTRA_ID, id)
            .put(EXTRA_TIME_MILLIS, timeMillis)
            .put(EXTRA_TITLE, title)
            .put(EXTRA_BODY, body)
            .put(EXTRA_DETAIL_TEXT, detailText)
            .put(EXTRA_TICKER, ticker)
            .put(EXTRA_SHORT_TEXT, shortText)
            .put(EXTRA_CLASS_START_MILLIS, classStartMillis)

        companion object {
            fun fromMap(map: Map<*, *>): LiveReminder? {
                val id = (map[EXTRA_ID] as? Number)?.toInt() ?: return null
                val timeMillis = (map[EXTRA_TIME_MILLIS] as? Number)?.toLong() ?: return null
                val title = map[EXTRA_TITLE]?.toString().orEmpty()
                val body = map[EXTRA_BODY]?.toString().orEmpty()
                val detailText = map[EXTRA_DETAIL_TEXT]?.toString().orEmpty()
                val ticker = map[EXTRA_TICKER]?.toString().orEmpty()
                val shortText = map[EXTRA_SHORT_TEXT]?.toString().orEmpty()
                val classStartMillis =
                    (map[EXTRA_CLASS_START_MILLIS] as? Number)?.toLong() ?: return null
                return LiveReminder(
                    id,
                    timeMillis,
                    title,
                    body,
                    detailText,
                    ticker,
                    shortText,
                    classStartMillis,
                )
            }

            fun fromJson(json: JSONObject): LiveReminder? {
                val id = json.optInt(EXTRA_ID, 0)
                val timeMillis = json.optLong(EXTRA_TIME_MILLIS, 0)
                val classStartMillis = json.optLong(EXTRA_CLASS_START_MILLIS, 0)
                if (id == 0 || timeMillis == 0L || classStartMillis == 0L) return null
                return LiveReminder(
                    id = id,
                    timeMillis = timeMillis,
                    title = json.optString(EXTRA_TITLE),
                    body = json.optString(EXTRA_BODY),
                    detailText = json.optString(EXTRA_DETAIL_TEXT),
                    ticker = json.optString(EXTRA_TICKER),
                    shortText = json.optString(EXTRA_SHORT_TEXT),
                    classStartMillis = classStartMillis,
                )
            }
        }
    }

    fun schedule(context: Context, reminders: List<LiveReminder>): List<Int> {
        val future = reminders.filter { it.timeMillis > System.currentTimeMillis() }
        persist(context, future)
        future.forEach { scheduleAlarm(context, it) }
        return future.map { it.id }
    }

    fun cancel(context: Context, ids: List<Int>) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val stored = readPersisted(context)
        val cancelIds = if (ids.isEmpty()) stored.map { it.id } else ids

        cancelIds.forEach { id ->
            alarmManager.cancel(pendingIntent(context, id, null))
            alarmManager.cancel(dismissPendingIntent(context, id))
            notificationManager.cancel(id)
        }

        if (ids.isEmpty()) {
            persist(context, emptyList())
        } else {
            persist(context, stored.filterNot { it.id in ids })
        }
    }

    fun reschedulePersisted(context: Context) {
        val future = readPersisted(context)
            .filter { it.timeMillis > System.currentTimeMillis() }
        persist(context, future)
        future.forEach { scheduleAlarm(context, it) }
    }

    fun backgroundStatus(context: Context): Map<String, Any> {
        return mapOf(
            "supported" to true,
            "manufacturer" to Build.MANUFACTURER.orEmpty(),
            "sdkInt" to Build.VERSION.SDK_INT,
            "isIgnoringBatteryOptimizations" to isIgnoringBatteryOptimizations(context),
            "canScheduleExactAlarms" to canScheduleExactAlarms(context),
        )
    }

    fun requestBatteryOptimizationExemption(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoringBatteryOptimizations(activity)) return true

        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:${activity.packageName}")
        }
        return startActivitySafely(activity, intent) ||
            startActivitySafely(activity, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    fun openExactAlarmSettings(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || canScheduleExactAlarms(activity)) {
            return true
        }
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:${activity.packageName}")
        }
        return startActivitySafely(activity, intent) ||
            startActivitySafely(
                activity,
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${activity.packageName}")
                },
            )
    }

    fun openBackgroundKeepAliveSettings(activity: Activity): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val intents = mutableListOf<Intent>()

        when {
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") ||
                manufacturer.contains("poco") -> {
                intents += Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    ),
                )
                intents += Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.powercenter.PowerSettings",
                    ),
                )
            }
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> {
                intents += Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ),
                )
                intents += Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.optimize.process.ProtectActivity",
                    ),
                )
            }
            manufacturer.contains("oppo") || manufacturer.contains("realme") ||
                manufacturer.contains("oneplus") -> {
                intents += Intent().setComponent(
                    ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.startupapp.StartupAppListActivity",
                    ),
                )
                intents += Intent().setComponent(
                    ComponentName(
                        "com.oplus.battery",
                        "com.oplus.powermanager.fuelgaue.PowerUsageModelActivity",
                    ),
                )
            }
            manufacturer.contains("vivo") || manufacturer.contains("iqoo") -> {
                intents += Intent().setComponent(
                    ComponentName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                    ),
                )
                intents += Intent().setComponent(
                    ComponentName(
                        "com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                    ),
                )
            }
            manufacturer.contains("samsung") -> {
                intents += Intent().setComponent(
                    ComponentName(
                        "com.samsung.android.lool",
                        "com.samsung.android.sm.ui.battery.BatteryActivity",
                    ),
                )
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            intents += Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${activity.packageName}")
        }

        return intents.any { startActivitySafely(activity, it) }
    }

    fun show(context: Context, reminder: LiveReminder) {
        ensureChannel(context)

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = if (launchIntent == null) {
            null
        } else {
            PendingIntent.getActivity(
                context,
                reminder.id,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val dismissIntent = dismissPendingIntent(context, reminder.id)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(reminder.title)
            .setContentText(reminder.body)
            .setTicker(reminder.ticker)
            .setSubText("课前静音提醒")
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setShowWhen(true)
            .setWhen(reminder.classStartMillis)
            .setUsesChronometer(true)
            .setDefaults(0)
            .setSound(null)
            .setVibrate(longArrayOf(0L))
            .setColor(0xFF4F46E5.toInt())
            .setDeleteIntent(dismissIntent)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            builder.setChronometerCountDown(true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            builder.setStyle(
                Notification.BigTextStyle(builder)
                    .bigText(reminder.detailText)
                    .setBigContentTitle(reminder.title)
                    .setSummaryText("静音提醒 · 即将上课"),
            )
        }

        if (contentIntent != null) {
            builder.setContentIntent(contentIntent)
            builder.addAction(0, "查看课表", contentIntent)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(6 * 60 * 1000L)
        }
        builder.addAction(0, "忽略本次", dismissIntent)

        requestPromotedOngoing(builder, reminder.shortText)

        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(reminder.id, builder.build())
    }

    private fun scheduleAlarm(context: Context, reminder: LiveReminder) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pendingIntent = pendingIntent(context, reminder.id, reminder)

        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    !alarmManager.canScheduleExactAlarms() ->
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        reminder.timeMillis,
                        pendingIntent,
                    )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        reminder.timeMillis,
                        pendingIntent,
                    )
                else ->
                    @Suppress("DEPRECATION")
                    alarmManager.setExact(
                        AlarmManager.RTC_WAKEUP,
                        reminder.timeMillis,
                        pendingIntent,
                    )
            }
        } catch (_: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    reminder.timeMillis,
                    pendingIntent,
                )
            } else {
                @Suppress("DEPRECATION")
                alarmManager.set(AlarmManager.RTC_WAKEUP, reminder.timeMillis, pendingIntent)
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return alarmManager.canScheduleExactAlarms()
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

    private fun pendingIntent(
        context: Context,
        id: Int,
        reminder: LiveReminder?,
    ): PendingIntent {
        val intent = Intent(context, CourseReminderLiveReceiver::class.java).apply {
            if (reminder != null) {
                putExtra(EXTRA_ID, reminder.id)
                putExtra(EXTRA_TIME_MILLIS, reminder.timeMillis)
                putExtra(EXTRA_TITLE, reminder.title)
                putExtra(EXTRA_BODY, reminder.body)
                putExtra(EXTRA_DETAIL_TEXT, reminder.detailText)
                putExtra(EXTRA_TICKER, reminder.ticker)
                putExtra(EXTRA_SHORT_TEXT, reminder.shortText)
                putExtra(EXTRA_CLASS_START_MILLIS, reminder.classStartMillis)
            }
        }
        return PendingIntent.getBroadcast(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun dismissPendingIntent(context: Context, id: Int): PendingIntent {
        val intent = Intent(context, CourseReminderLiveReceiver::class.java).apply {
            action = ACTION_DISMISS_REMINDER
            putExtra(EXTRA_ID, id)
        }
        return PendingIntent.getBroadcast(
            context,
            id xor 0x40000000.toInt(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            NOTIFICATION_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "上课前 5 分钟静音提醒"
            setSound(null, null)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun requestPromotedOngoing(builder: Notification.Builder, shortText: String) {
        if (Build.VERSION.SDK_INT < 36) return
        runCatching {
            builder.javaClass
                .getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType!!)
                .invoke(builder, true)
        }
        if (shortText.isNotBlank()) {
            runCatching {
                builder.javaClass
                    .getMethod("setShortCriticalText", CharSequence::class.java)
                    .invoke(builder, shortText.take(7))
            }
        }
    }

    private fun persist(context: Context, reminders: List<LiveReminder>) {
        val array = JSONArray()
        reminders.forEach { array.put(it.toJson()) }
        context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PREFS_REMINDERS, array.toString())
            .apply()
    }

    private fun readPersisted(context: Context): List<LiveReminder> {
        val raw = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(PREFS_REMINDERS, null) ?: return emptyList()
        val array = JSONArray(raw)
        return buildList {
            for (index in 0 until array.length()) {
                LiveReminder.fromJson(array.getJSONObject(index))?.let(::add)
            }
        }
    }

    private fun removePersisted(context: Context, id: Int) {
        persist(context, readPersisted(context).filterNot { it.id == id })
    }

    fun dismissShownReminder(context: Context, id: Int) {
        if (id == 0) return
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(id)
        removePersisted(context, id)
    }
}

class CourseReminderLiveReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "com.example.shenliyuan.action.DISMISS_COURSE_REMINDER") {
            CourseReminderLiveScheduler.dismissShownReminder(
                context,
                intent.getIntExtra("id", 0),
            )
            return
        }
        val id = intent.getIntExtra("id", 0)
        val timeMillis = intent.getLongExtra("timeMillis", 0)
        if (id == 0 || timeMillis == 0L) return

        CourseReminderLiveScheduler.show(
            context,
            CourseReminderLiveScheduler.LiveReminder(
                id = id,
                timeMillis = timeMillis,
                title = intent.getStringExtra("title").orEmpty(),
                body = intent.getStringExtra("body").orEmpty(),
                detailText = intent.getStringExtra("detailText").orEmpty(),
                ticker = intent.getStringExtra("ticker").orEmpty(),
                shortText = intent.getStringExtra("shortText").orEmpty(),
                classStartMillis = intent.getLongExtra("classStartMillis", 0),
            ),
        )
    }
}

class CourseReminderLiveBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CourseReminderLiveScheduler.reschedulePersisted(context)
    }
}
