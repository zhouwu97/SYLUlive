package com.example.shenliyuan

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

abstract class BaseHomeWidgetProvider(
    private val variant: NativeWidgetVariant,
) : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(
                appWidgetId,
                HomeWidgetRenderer.build(context, appWidgetId, variant),
            )
        }
        if (appWidgetIds.isNotEmpty()) {
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, variant.listViewId)
        }
    }
}

class TodayCourseWidget2x2Provider :
    BaseHomeWidgetProvider(NativeWidgetVariant.COURSE_2X2)

class TodayCourseWidget4x2Provider :
    BaseHomeWidgetProvider(NativeWidgetVariant.COURSE_4X2)

class ExamWidget2x2Provider :
    BaseHomeWidgetProvider(NativeWidgetVariant.EXAM_2X2)

class ExamWidget4x2Provider :
    BaseHomeWidgetProvider(NativeWidgetVariant.EXAM_4X2)
