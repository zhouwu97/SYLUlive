package com.example.shenliyuan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 持久化系统通知点击，直到 Flutter 完成导航并显式确认。
 *
 * 队列用于保留用户连续点击的不同通知；限制长度可避免异常数据无限增长。
 */
object NotificationOpenStore {
    private const val PREFERENCES_NAME = "notification_open_store"
    private const val PENDING_EVENTS_KEY = "pending_events"
    private const val MAX_PENDING_EVENTS = 16
    private val lock = Any()

    fun enqueue(context: Context, payload: JSONObject): String = synchronized(lock) {
        val events = readEvents(context)
        while (events.length() >= MAX_PENDING_EVENTS) {
            events.remove(0)
        }

        val event = JSONObject().apply {
            put("id", UUID.randomUUID().toString())
            put("opened_at", System.currentTimeMillis())
            put("payload", payload)
        }
        events.put(event)
        writeEvents(context, events)
        event.toString()
    }

    fun peek(context: Context): String? = synchronized(lock) {
        val events = readEvents(context)
        if (events.length() == 0) null else events.optJSONObject(0)?.toString()
    }

    fun acknowledge(context: Context, eventId: String): Boolean = synchronized(lock) {
        val events = readEvents(context)
        val remaining = JSONArray()
        var removed = false

        for (index in 0 until events.length()) {
            val event = events.optJSONObject(index) ?: continue
            if (event.optString("id") == eventId) {
                removed = true
            } else {
                remaining.put(event)
            }
        }

        if (removed) {
            writeEvents(context, remaining)
        }
        removed
    }

    private fun readEvents(context: Context): JSONArray {
        val raw = preferences(context).getString(PENDING_EVENTS_KEY, null)
            ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun writeEvents(context: Context, events: JSONArray) {
        preferences(context)
            .edit()
            .putString(PENDING_EVENTS_KEY, events.toString())
            .commit()
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
}
