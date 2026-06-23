package com.example.shenliyuan

import android.content.Context
import cn.jpush.android.api.JPushInterface

object PrivateMessageNotificationStore {
    private const val PREFS = "private_message_notification_ids"

    private val lock = Any()

    private fun key(conversationId: Long) = "conversation_$conversationId"

    fun record(
        context: Context,
        conversationId: Long,
        notificationId: Int,
    ) {
        if (notificationId <= 0) return

        synchronized(lock) {
            val prefs = context.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE,
            )

            val ids = HashSet(
                prefs.getStringSet(
                    key(conversationId),
                    emptySet(),
                ).orEmpty()
            )

            ids.add(notificationId.toString())

            prefs.edit()
                .putStringSet(key(conversationId), ids)
                .apply()
        }
    }

    fun remove(
        context: Context,
        conversationId: Long,
        notificationId: Int,
    ) {
        if (notificationId <= 0) return

        synchronized(lock) {
            val prefs = context.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE,
            )

            val ids = HashSet(
                prefs.getStringSet(
                    key(conversationId),
                    emptySet(),
                ).orEmpty()
            )

            if (ids.remove(notificationId.toString())) {
                prefs.edit()
                    .putStringSet(key(conversationId), ids)
                    .apply()
            }
        }
    }

    fun clear(
        context: Context,
        conversationId: Long,
    ) {
        val ids = synchronized(lock) {
            val prefs = context.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE,
            )
            val k = key(conversationId)

            val stored = prefs.getStringSet(k, emptySet())
                .orEmpty()
                .mapNotNull(String::toIntOrNull)
                .toSet()

            prefs.edit()
                .remove(k)
                .apply()
            
            stored
        }

        ids.forEach { id ->
            runCatching {
                JPushInterface.clearNotificationById(
                    context.applicationContext,
                    id,
                )
            }
        }
    }
}

