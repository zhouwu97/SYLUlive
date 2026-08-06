package com.example.shenliyuan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 持久化系统通知点击，直到 Flutter 完成导航并显式确认。
 *
 * 较新的点击完成后会淘汰更早的点击，避免恢复阶段连续执行过时导航。
 */
object NotificationOpenStore {
    private const val PREFERENCES_NAME = "notification_open_store"
    private const val PENDING_EVENTS_KEY = "pending_events"
    private const val MAX_PENDING_EVENTS = 16
    private const val MAX_EVENT_AGE_MILLIS = 24L * 60L * 60L * 1000L
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
        if (events.length() == 0) {
            null
        } else {
            events.optJSONObject(events.length() - 1)?.toString()
        }
    }

    fun clear(context: Context) = synchronized(lock) {
        preferences(context)
            .edit()
            .remove(PENDING_EVENTS_KEY)
            .commit()
    }

    fun acknowledge(context: Context, eventId: String): Boolean = synchronized(lock) {
        val events = readEvents(context)
        var acknowledgedIndex = -1
        for (index in 0 until events.length()) {
            if (events.optJSONObject(index)?.optString("id") == eventId) {
                acknowledgedIndex = index
                break
            }
        }
        if (acknowledgedIndex < 0) return@synchronized false

        val remaining = JSONArray()
        for (index in (acknowledgedIndex + 1) until events.length()) {
            events.optJSONObject(index)?.let(remaining::put)
        }
        writeEvents(context, remaining)
        true
    }

    private fun readEvents(context: Context): JSONArray {
        val raw = preferences(context).getString(PENDING_EVENTS_KEY, null)
            ?: return JSONArray()
        return try {
            removeExpiredEvents(context, JSONArray(raw))
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun removeExpiredEvents(context: Context, events: JSONArray): JSONArray {
        val now = System.currentTimeMillis()
        val active = JSONArray()
        var changed = false

        for (index in 0 until events.length()) {
            val event = events.optJSONObject(index)
            val openedAt = event?.optLong("opened_at", -1L) ?: -1L
            if (event == null || openedAt <= 0L || now - openedAt > MAX_EVENT_AGE_MILLIS) {
                changed = true
            } else {
                active.put(event)
            }
        }

        if (changed) {
            writeEvents(context, active)
        }
        return active
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
