package com.example.shenliyuan

import android.app.ActivityManager
import android.content.Context

object PrivateMessageNotificationState {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY_CURRENT_CONVERSATION_ID =
        "flutter.private_message_current_conversation_id"
    private const val KEY_APP_FOREGROUND =
        "flutter.private_message_app_foreground"

    fun setCurrentConversationId(context: Context, conversationId: Long?) {
        val editor = prefs(context).edit()
        if (conversationId == null) {
            editor.remove(KEY_CURRENT_CONVERSATION_ID)
        } else {
            editor.putLong(KEY_CURRENT_CONVERSATION_ID, conversationId)
        }
        editor.apply()
    }

    fun currentConversationId(context: Context): Long? {
        val prefs = prefs(context)
        if (!prefs.contains(KEY_CURRENT_CONVERSATION_ID)) return null
        return prefs.getLong(KEY_CURRENT_CONVERSATION_ID, -1L)
            .takeIf { it > 0L }
    }

    fun setAppForeground(context: Context, foreground: Boolean) {
        prefs(context).edit().putBoolean(KEY_APP_FOREGROUND, foreground).apply()
    }

    fun isAppForeground(context: Context): Boolean {
        return prefs(context).getBoolean(KEY_APP_FOREGROUND, false)
    }

    fun isActiveConversationForeground(context: Context, conversationId: Long): Boolean {
        return isAppForeground(context) &&
            isAppProcessForeground(context) &&
            currentConversationId(context) == conversationId
    }

    private fun isAppProcessForeground(context: Context): Boolean {
        val manager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return false
        val packageName = context.packageName
        return manager.runningAppProcesses
            ?.any { process ->
                process.processName == packageName &&
                    (process.importance ==
                        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
                        process.importance ==
                        ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE)
            } == true
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(
            PREFS_NAME,
            Context.MODE_PRIVATE,
        )
}
