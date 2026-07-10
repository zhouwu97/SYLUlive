package com.example.shenliyuan

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context

enum class NativeHomeWidgetSize(val storageName: String) {
    SIZE_2X2("2x2"),
    SIZE_2X4("2x4"),
}

enum class NativeWidgetVariant(
    val kind: NativeHomeWidgetKind,
    val size: NativeHomeWidgetSize,
    val providerClass: Class<out AppWidgetProvider>,
    val layoutResource: Int,
    val itemLayoutResource: Int,
    val listViewId: Int,
    val maxItems: Int,
) {
    COURSE_2X2(
        NativeHomeWidgetKind.COURSE,
        NativeHomeWidgetSize.SIZE_2X2,
        TodayCourseWidget2x2Provider::class.java,
        R.layout.widget_course_2x2,
        R.layout.widget_course_item_compact,
        R.id.course_list_view,
        2,
    ),
    COURSE_2X4(
        NativeHomeWidgetKind.COURSE,
        NativeHomeWidgetSize.SIZE_2X4,
        TodayCourseWidget2x4Provider::class.java,
        R.layout.widget_course_2x4,
        R.layout.widget_course_item_detailed,
        R.id.course_list_view,
        6,
    ),
    EXAM_2X2(
        NativeHomeWidgetKind.EXAM,
        NativeHomeWidgetSize.SIZE_2X2,
        ExamWidget2x2Provider::class.java,
        R.layout.widget_exam_2x2,
        R.layout.widget_exam_item_compact,
        R.id.exam_list_view,
        2,
    ),
    EXAM_2X4(
        NativeHomeWidgetKind.EXAM,
        NativeHomeWidgetSize.SIZE_2X4,
        ExamWidget2x4Provider::class.java,
        R.layout.widget_exam_2x4,
        R.layout.widget_exam_item_detailed,
        R.id.exam_list_view,
        6,
    );

    companion object {
        fun fromName(
            value: String?,
            fallback: NativeWidgetVariant,
        ): NativeWidgetVariant = entries.firstOrNull { it.name == value } ?: fallback
    }
}

object HomeWidgetRegistry {
    const val EXTRA_VARIANT = "home_widget_variant"

    val variants: List<NativeWidgetVariant> = NativeWidgetVariant.entries

    fun find(kind: String?, size: String?): NativeWidgetVariant? {
        return variants.firstOrNull {
            it.kind.storageName == kind && it.size.storageName == size
        }
    }

    fun refreshAll(context: Context): Int {
        val manager = AppWidgetManager.getInstance(context)
        var refreshed = 0
        for (variant in variants) {
            val ids = manager.getAppWidgetIds(ComponentName(context, variant.providerClass))
            for (id in ids) {
                manager.updateAppWidget(id, HomeWidgetRenderer.build(context, id, variant))
                refreshed += 1
            }
            if (ids.isNotEmpty()) {
                manager.notifyAppWidgetViewDataChanged(ids, variant.listViewId)
            }
        }
        return refreshed
    }

    fun installedCounts(context: Context): Map<String, Int> {
        val manager = AppWidgetManager.getInstance(context)
        fun count(variant: NativeWidgetVariant): Int =
            manager.getAppWidgetIds(ComponentName(context, variant.providerClass)).size
        return mapOf(
            "course2x2" to count(NativeWidgetVariant.COURSE_2X2),
            "course2x4" to count(NativeWidgetVariant.COURSE_2X4),
            "exam2x2" to count(NativeWidgetVariant.EXAM_2X2),
            "exam2x4" to count(NativeWidgetVariant.EXAM_2X4),
        )
    }
}
