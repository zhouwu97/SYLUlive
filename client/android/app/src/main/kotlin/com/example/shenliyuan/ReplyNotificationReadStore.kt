package com.example.shenliyuan

import android.app.NotificationManager
import android.content.Context
import org.json.JSONObject

/** 已读回执按接收账号隔离，进程重启后仍阻止延迟到达的回复推送。 */
object ReplyNotificationReadStore {
    private const val PREFS = "reply_notification_read"

    @Synchronized
    fun record(context: Context, receipt: Map<*, *>) {
        val user = (receipt["recipient_user_id"] as? Number)?.toLong() ?: return
        if (user <= 0) return
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val ids = preferences.getStringSet("ids_$user", emptySet())!!.toMutableSet()
        val replies = preferences.getStringSet("replies_$user", emptySet())!!.toMutableSet()
        (receipt["ids"] as? List<*>)?.forEach { if (it is Number) ids.add(it.toLong().toString()) }
        (receipt["reply_ids"] as? List<*>)?.forEach { if (it is Number) replies.add(it.toLong().toString()) }
        val watermark = maxOf(preferences.getLong("all_$user", 0), (receipt["all_before_id"] as? Number)?.toLong() ?: 0)
        // 仅保留最近的单条回执；全部已读水位覆盖更早通知。
        preferences.edit()
            .putStringSet("ids_$user", ids.filter { it.toLong() > watermark }.sortedByDescending { it.toLong() }.take(2000).toSet())
            .putStringSet("replies_$user", replies.sortedByDescending { it.toLong() }.take(2000).toSet())
            .putLong("all_$user", watermark).apply()
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.activeNotifications.forEach { notification ->
            val extras = notification.notification.extras
            val read = listOf("cn.jpush.android.EXTRA", "cn.jpush.android.EXTRA_EXTRA")
                .any { key -> isRead(context, extras.getString(key)) }
            if (read) manager.cancel(notification.tag, notification.id)
        }
    }

    @Synchronized
    fun isRead(context: Context, raw: String?): Boolean {
        val data = try { JSONObject(raw ?: return false) } catch (_: Exception) { return false }
        if (data.optString("type") != "reply") return false
        val user = data.optLong("recipient_user_id", 0)
        if (user <= 0) return false
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val id = data.optLong("notification_id", 0)
        val reply = data.optLong("reply_id", 0)
        return (id > 0 && (id <= preferences.getLong("all_$user", 0) || preferences.getStringSet("ids_$user", emptySet())!!.contains(id.toString()))) ||
            (reply > 0 && preferences.getStringSet("replies_$user", emptySet())!!.contains(reply.toString()))
    }
}
