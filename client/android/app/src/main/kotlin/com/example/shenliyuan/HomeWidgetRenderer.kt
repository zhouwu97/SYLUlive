package com.example.shenliyuan

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.TypedValue
import android.widget.RemoteViews

object HomeWidgetRenderer {
    fun build(
        context: Context,
        appWidgetId: Int,
        variant: NativeWidgetVariant,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, variant.layoutResource)
        val appearance = HomeWidgetAppearanceStore.read(context, variant.kind)
        val theme = HomeWidgetThemeConfig.resolve(context, appearance.theme)
        val typography = HomeWidgetTypography.resolve(variant.size, appearance.fontSize)

        views.setInt(android.R.id.background, "setBackgroundResource", theme.backgroundResource)
        views.setTextViewText(R.id.tv_widget_title, appearance.title)
        views.setTextViewTextSize(
            R.id.tv_widget_title,
            TypedValue.COMPLEX_UNIT_SP,
            typography.titleSp,
        )
        views.setTextColor(R.id.tv_widget_title, theme.primaryTextColor)
        views.setTextViewTextSize(
            R.id.empty_view,
            TypedValue.COMPLEX_UNIT_SP,
            typography.emptySp,
        )
        views.setTextColor(R.id.empty_view, theme.mutedTextColor)

        if (variant.kind == NativeHomeWidgetKind.COURSE) {
            val data = CourseDataReader.read(context)
            views.setTextViewText(R.id.tv_widget_date, data.date)
            views.setTextViewTextSize(
                R.id.tv_widget_date,
                TypedValue.COMPLEX_UNIT_SP,
                typography.subtitleSp,
            )
            views.setTextColor(R.id.tv_widget_date, theme.secondaryTextColor)
        }

        val action = if (variant.kind == NativeHomeWidgetKind.COURSE) {
            "com.example.shenliyuan.ACTION_WIDGET_TIMETABLE"
        } else {
            "com.example.shenliyuan.ACTION_WIDGET_EXAM"
        }
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            this.action = action
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val baseRequestCode = appWidgetId * 10 + variant.ordinal * 2
        val launchPendingIntent = PendingIntent.getActivity(
            context,
            baseRequestCode,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(android.R.id.background, launchPendingIntent)
        views.setOnClickPendingIntent(R.id.empty_view, launchPendingIntent)

        val serviceClass = if (variant.kind == NativeHomeWidgetKind.COURSE) {
            CourseWidgetService::class.java
        } else {
            ExamWidgetService::class.java
        }
        val serviceIntent = Intent(context, serviceClass).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            putExtra(HomeWidgetRegistry.EXTRA_VARIANT, variant.name)
            putExtra(
                HomeWidgetRegistry.EXTRA_RESOLVED_THEME,
                theme.resolvedTheme.storageName,
            )
            putExtra(HomeWidgetRegistry.EXTRA_FONT_SIZE, appearance.fontSize.storageName)
            // RemoteViewsService 会按 Intent.filterEquals 缓存工厂；主题写进 data 才能让
            // 启动器在外观变化时放弃旧列表，避免新背景继续复用旧文字颜色。
            data = Uri.Builder()
                .scheme("shenliyuan-widget")
                .authority(variant.name.lowercase())
                .appendPath(appWidgetId.toString())
                .appendQueryParameter(
                    "appearance",
                    "${theme.resolvedTheme.storageName}-${appearance.fontSize.storageName}",
                )
                .build()
        }
        views.setRemoteAdapter(variant.listViewId, serviceIntent)
        views.setEmptyView(variant.listViewId, R.id.empty_view)

        val templatePendingIntent = PendingIntent.getActivity(
            context,
            baseRequestCode + 1,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        views.setPendingIntentTemplate(variant.listViewId, templatePendingIntent)
        return views
    }
}
