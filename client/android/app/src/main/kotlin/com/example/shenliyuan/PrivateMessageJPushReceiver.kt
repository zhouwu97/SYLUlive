package com.example.shenliyuan

import android.content.Context
import cn.jpush.android.api.NotificationMessage
import com.jiguang.jpush.JPushEventReceiver
import org.json.JSONObject

class PrivateMessageJPushReceiver : JPushEventReceiver() {
    override fun isNeedShowNotification(
        context: Context,
        notificationMessage: NotificationMessage,
        processName: String,
    ): Boolean {
        val conversationId = conversationIdFrom(notificationMessage)
            ?: return super.isNeedShowNotification(context, notificationMessage, processName)

        if (PrivateMessageNotificationState.isActiveConversationForeground(context, conversationId)) {
            return false
        }

        return super.isNeedShowNotification(context, notificationMessage, processName)
    }

    private fun conversationIdFrom(notificationMessage: NotificationMessage): Long? {
        val extras = notificationMessage.notificationExtras ?: return null
        return try {
            JSONObject(extras).optString("conversation_id").toLongOrNull()
        } catch (_: Exception) {
            null
        }
    }
}
