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

    private fun show(androidId: Int) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("reply_notifications_v1", "互动回复", NotificationManager.IMPORTANCE_HIGH))
        manager.notify("jpush", androidId, Notification.Builder(context, "reply_notifications_v1")
            .setSmallIcon(android.R.drawable.ic_dialog_info).build())
    }

    @Test fun `extras 缺失时通过 SDK 到达记录清理且保留其他账号和回复`() {
        listOf(1, 2, 3, 4).forEach(::show)
        ReplyNotificationReadStore.trackDisplayed(context, 1, payload(7, 100))
        ReplyNotificationReadStore.trackDisplayed(context, 2, payload(8, 100))
        ReplyNotificationReadStore.trackDisplayed(context, 3, payload(7, 101, 12))
        ReplyNotificationReadStore.trackDisplayed(context, 4, payload(7, 100).replace("reply", "private_message"))
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "ids" to listOf(100)))
        assertEquals(setOf(2, 3, 4), context.getSystemService(NotificationManager::class.java).activeNotifications.map { it.id }.toSet())
        val saved = context.getSharedPreferences("reply_notification_read", Context.MODE_PRIVATE).getString("displayed", "{}")!!
        assertFalse(JSONObject(saved).has("1"))
        assertTrue(JSONObject(saved).has("2"))
    }

    @Test fun `已读后延迟到达的系统通知会清理`() {
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "reply_ids" to listOf(11)))
        show(1)
        ReplyNotificationReadStore.trackDisplayed(context, 1, payload(7, 100))
        assertEquals(0, context.getSystemService(NotificationManager::class.java).activeNotifications.size)
    }

    @Test fun `复用系统 ID 不会按旧记录误清新回复或私信`() {
        show(1)
        ReplyNotificationReadStore.trackDisplayed(context, 1, payload(7, 100))
        ReplyNotificationReadStore.trackDisplayed(context, 1, payload(7, 101, 12))
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "ids" to listOf(100)))
        assertEquals(1, context.getSystemService(NotificationManager::class.java).activeNotifications.size)
        ReplyNotificationReadStore.trackDisplayed(context, 1, "{\"type\":\"private_message\"}")
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "ids" to listOf(101)))
        assertEquals(1, context.getSystemService(NotificationManager::class.java).activeNotifications.size)
    }

    @Test fun `通知移除后删除映射且过期记录不参与清理`() {
        ReplyNotificationReadStore.trackDisplayed(context, 1, payload(7, 100))
        ReplyNotificationReadStore.removeDisplayed(context, 1)
        val prefs = context.getSharedPreferences("reply_notification_read", Context.MODE_PRIVATE)
        assertFalse(JSONObject(prefs.getString("displayed", "{}")!!).has("1"))
        prefs.edit().putString("displayed", JSONObject().put("2", JSONObject(payload(7, 100))
            .put("recorded_at", 1)).toString()).commit()
        show(2)
        ReplyNotificationReadStore.record(context, mapOf("recipient_user_id" to 7, "ids" to listOf(100)))
        assertEquals(1, context.getSystemService(NotificationManager::class.java).activeNotifications.size)
        assertEquals(0, JSONObject(prefs.getString("displayed", "{}")!!).length())
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
