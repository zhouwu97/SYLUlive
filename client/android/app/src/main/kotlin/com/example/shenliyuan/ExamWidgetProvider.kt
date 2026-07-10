package com.example.shenliyuan

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/**
 * 兼容旧版桌面的壳 Provider，其内容实际上委托给 2x2 的新考试组件逻辑。
 */
class ExamWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        // 直接使用 2x2 的渲染逻辑
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                appWidgetId,
                HomeWidgetRenderer.build(context, appWidgetId, NativeWidgetVariant.EXAM_2X2)
            )
        }
    }
}
