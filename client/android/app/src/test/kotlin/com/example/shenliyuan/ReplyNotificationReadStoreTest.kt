package com.example.shenliyuan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class ReplyNotificationReadStoreTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private fun payload(user: Long, id: Long, reply: Long = 11): String = JSONObject()
        .put("type", "reply").put("recipient_user_id", user).put("notification_id", id).put("reply_id", reply).toString()

    @Before fun reset() {
        context.getSharedPreferences("reply_notification_read", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSystemService(NotificationManager::class.java).cancelAll()
    }

    @Test fun `单条已读清除系统通知且不影响其他账号和未读回复`() {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("reply_notifications_v1", "互动回复", NotificationManager.IMPORTANCE_HIGH))
        val extras = Bundle().apply { putString("cn.jpush.android.EXTRA", payload(7, 100)) }
        manager.notify("jpush", 1, Notification.Builder(context, "reply_notifications_v1").setSmallIcon(android.R.drawable.ic_dialog_info).addExtras(extras).build())
        assertEquals(1, manager.activeNotifications.size)
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "ids" to listOf(100), "reply_ids" to listOf(11)))
        assertEquals(0, manager.activeNotifications.size)
        assertTrue(ReplyNotificationReadStore.isRead(context, payload(7, 100)))
        assertTrue(ReplyNotificationReadStore.isRead(context, payload(7, 0)))
        assertFalse(ReplyNotificationReadStore.isRead(context, payload(8, 100)))
        assertFalse(ReplyNotificationReadStore.isRead(context, payload(7, 101, 12)))
    }

    @Test fun `全部已读水位不会吞掉新通知也不会清除私信`() {
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "all_before_id" to 100))
        assertTrue(ReplyNotificationReadStore.isRead(context, payload(7, 99)))
        assertFalse(ReplyNotificationReadStore.isRead(context, payload(7, 101)))
        assertFalse(ReplyNotificationReadStore.isRead(context, payload(8, 99)))
        assertFalse(ReplyNotificationReadStore.isRead(context, payload(7, 99).replace("reply", "private_message")))
        assertFalse(ReplyNotificationReadStore.isRead(context, "malformed"))
    }
}
