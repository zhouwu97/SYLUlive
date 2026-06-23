package com.example.shenliyuan

import android.content.Context
import android.content.Intent
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

    override fun onNotifyMessageArrived(
        context: Context,
        notificationMessage: NotificationMessage,
    ) {
        val conversationId = conversationIdFrom(notificationMessage)

        if (conversationId != null &&
            notificationMessage.notificationId > 0) {
            PrivateMessageNotificationStore.record(
                context,
                conversationId,
                notificationMessage.notificationId,
            )
        }

        super.onNotifyMessageArrived(context, notificationMessage)
    }

    override fun onNotifyMessageOpened(
        context: Context,
        notificationMessage: NotificationMessage,
    ) {
        val extras = notificationMessage.notificationExtras.orEmpty()
        val json = try {
            JSONObject(extras)
        } catch (_: Exception) {
            null
        }

        val isPrivateMessage =
            json?.optString("type") == "private_message"

        val conversationId =
            json?.optString("conversation_id")?.toLongOrNull()

        if (!isPrivateMessage || conversationId == null) {
            // 非私信继续交给 Flutter 插件原有逻辑
            super.onNotifyMessageOpened(context, notificationMessage)
            return
        }

        PrivateMessageNotificationStore.clear(
            context,
            conversationId,
        )

        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_PRIVATE_MESSAGE
            putExtra(
                MainActivity.EXTRA_PRIVATE_MESSAGE_JSON,
                extras,
            )
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }

        context.startActivity(intent)

        // 私信这里不要再调用 super，避免 Flutter 插件重复派发点击事件
    }

    override fun onNotifyMessageDismiss(
        context: Context,
        notificationMessage: NotificationMessage,
    ) {
        val conversationId = conversationIdFrom(notificationMessage)
        val notificationId = notificationMessage.notificationId

        if (conversationId != null && notificationId > 0) {
            PrivateMessageNotificationStore.remove(
                context,
                conversationId,
                notificationId,
            )
        }

        super.onNotifyMessageDismiss(context, notificationMessage)
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
