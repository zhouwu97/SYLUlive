package com.example.shenliyuan

import android.app.NotificationManager
import android.content.Context
import cn.jpush.android.api.JPushInterface
import org.json.JSONObject

/** 已读回执按接收账号隔离，进程重启后仍阻止延迟到达的回复推送。 */
object ReplyNotificationReadStore {
    private const val PREFS = "reply_notification_read"
    private const val DISPLAYED = "displayed"
    private const val MAX_DISPLAYED = 2000
    private const val DISPLAYED_TTL = 30L * 24 * 60 * 60 * 1000

    /** SDK 回调中的系统 ID 比通知 extras 更可靠；只保存匹配所需元数据。 */
    @Synchronized
    fun trackDisplayed(context: Context, androidId: Int, raw: String?) {
        if (androidId <= 0) return
        val displayed = displayed(context)
        // 系统 ID 可能被 SDK 复用，任何新到达通知都必须替换旧映射。
        displayed.remove(androidId.toString())
        val data = runCatching { JSONObject(raw ?: "") }.getOrNull()
        if (data?.optString("type") == "reply" &&
            data.optLong("recipient_user_id") > 0 &&
            (data.optLong("notification_id") > 0 || data.optLong("reply_id") > 0)) {
            displayed.put(androidId.toString(), JSONObject()
                .put("type", "reply")
                .put("recipient_user_id", data.optLong("recipient_user_id"))
                .put("notification_id", data.optLong("notification_id"))
                .put("reply_id", data.optLong("reply_id"))
                .put("recorded_at", System.currentTimeMillis()))
            if (isRead(context, data.toString())) {
                clearSystemNotification(context, androidId)
                displayed.remove(androidId.toString())
            }
        }
        saveDisplayed(context, displayed)
    }

    @Synchronized
    fun removeDisplayed(context: Context, androidId: Int) {
        val displayed = displayed(context)
        displayed.remove(androidId.toString())
        saveDisplayed(context, displayed)
    }

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
        val displayed = displayed(context)
        manager.activeNotifications.forEach { notification ->
            val extras = notification.notification.extras
            val read = listOf("cn.jpush.android.EXTRA", "cn.jpush.android.EXTRA_EXTRA")
                .any { key -> isReadFor(context, extras.getString(key), user) }
            if (read) manager.cancel(notification.tag, notification.id)
        }
        displayed.keys().asSequence().toList().forEach { key ->
            if (isReadFor(context, displayed.optJSONObject(key)?.toString(), user)) {
                key.toIntOrNull()?.let { clearSystemNotification(context, it) }
                displayed.remove(key)
            }
        }
        saveDisplayed(context, displayed)
    }

    private fun isReadFor(context: Context, raw: String?, user: Long): Boolean {
        val data = runCatching { JSONObject(raw ?: "") }.getOrNull() ?: return false
        return data.optLong("recipient_user_id") == user && isRead(context, raw)
    }

    private fun clearSystemNotification(context: Context, androidId: Int) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.activeNotifications.filter { it.id == androidId }.forEach {
            manager.cancel(it.tag, it.id)
        }
        // 同步 SDK 内部记录，防止 SDK 继续显示已消费的回复。
        runCatching { JPushInterface.clearNotificationById(context.applicationContext, androidId) }
    }

    private fun displayed(context: Context): JSONObject {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val data = runCatching { JSONObject(preferences.getString(DISPLAYED, "{}")!!) }
            .getOrDefault(JSONObject())
        val cutoff = System.currentTimeMillis() - DISPLAYED_TTL
        data.keys().asSequence().toList().forEach { key ->
            if ((data.optJSONObject(key)?.optLong("recorded_at") ?: 0) < cutoff) data.remove(key)
        }
        return data
    }

    private fun saveDisplayed(context: Context, displayed: JSONObject) {
        val sorted = displayed.keys().asSequence().toList()
            .sortedByDescending { displayed.optJSONObject(it)?.optLong("recorded_at") ?: 0 }
        sorted.drop(MAX_DISPLAYED).forEach { displayed.remove(it) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(DISPLAYED, displayed.toString()).apply()
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
