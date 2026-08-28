package com.example.shenliyuan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 监听系统日期与时间变更广播，自动触发桌面小组件全量刷新。
 *
 * 监听动作：
 * - Intent.ACTION_DATE_CHANGED (跨过凌晨 00:00)
 * - Intent.ACTION_TIME_SET (手动调整时间)
 * - Intent.ACTION_TIMEZONE_CHANGED (时区切换)
 */
class WidgetDateChangeReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "WidgetDateChangeReceiver"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return
        val action = intent?.action
        Log.d(TAG, "收到系统时间/日期变更广播: $action")
        try {
            val count = HomeWidgetRegistry.refreshAll(context)
            Log.d(TAG, "桌面小组件已刷新 ($count 个实例)")
        } catch (e: Exception) {
            Log.e(TAG, "刷新小组件失败", e)
        }
    }
}
