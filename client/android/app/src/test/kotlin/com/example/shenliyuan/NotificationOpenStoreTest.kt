package com.example.shenliyuan

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class NotificationOpenStoreTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        NotificationOpenStore.clear(context)
    }

    @After
    fun tearDown() {
        NotificationOpenStore.clear(context)
    }

    @Test
    fun `恢复最新事件后确认会清除全部旧事件`() {
        NotificationOpenStore.enqueue(context, payload("A"))
        NotificationOpenStore.enqueue(context, payload("B"))
        val latest = NotificationOpenStore.enqueue(context, payload("C"))

        assertEquals("C", peekLabel())
        NotificationOpenStore.acknowledge(context, JSONObject(latest).getString("id"))
        assertNull(NotificationOpenStore.peek(context))
    }

    @Test
    fun `确认旧事件后仍保留更新事件`() {
        val oldest = NotificationOpenStore.enqueue(context, payload("A"))
        NotificationOpenStore.enqueue(context, payload("B"))

        NotificationOpenStore.acknowledge(context, JSONObject(oldest).getString("id"))
        assertEquals("B", peekLabel())
    }

    private fun payload(label: String) = JSONObject().put("label", label)

    private fun peekLabel(): String? {
        val event = NotificationOpenStore.peek(context) ?: return null
        return JSONObject(event).getJSONObject("payload").getString("label")
    }
}
