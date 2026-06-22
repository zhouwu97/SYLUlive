package com.example.shenliyuan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class KeepAliveBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {
                DiagnosticLogStore.info(
                    context,
                    source = "系统",
                    type = "广播唤醒",
                    summary = "收到系统广播",
                    detail = "action=${intent.action}",
                )
                try {
                    KeepAliveForegroundService.startIfEnabled(context)
                } catch (e: Exception) {
                    DiagnosticLogStore.critical(
                        context,
                        level = "error",
                        source = "保活",
                        type = e.javaClass.simpleName,
                        summary = "系统广播恢复保活服务失败",
                        detail = android.util.Log.getStackTraceString(e),
                    )
                    return
                }
            }
        }
    }
}
