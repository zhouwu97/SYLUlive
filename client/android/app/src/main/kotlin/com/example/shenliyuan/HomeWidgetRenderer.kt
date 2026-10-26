package com.example.shenliyuan

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.TypedValue
import android.widget.RemoteViews
import android.widget.RemoteViewsService

object HomeWidgetRenderer {
    fun build(
        context: Context,
        appWidgetId: Int,
        variant: NativeWidgetVariant,
    ): RemoteViews {
        val appearance = HomeWidgetAppearanceStore.read(context, variant.kind)
        val views = RemoteViews(
            context.packageName,
            variant.rootLayoutResource(appearance.fontSize),
        )
        val theme = HomeWidgetThemeConfig.resolve(context, appearance.theme)
        val typography = HomeWidgetTypography.resolve(variant.size, appearance.fontSize)
        val courseData = if (variant.kind == NativeHomeWidgetKind.COURSE) {
            CourseDataReader.read(context)
        } else {
            null
        }

        // 材质覆盖整个根容器，列表行保持透明，避免出现局部实色块或叠加边框。
        views.setInt(android.R.id.background, "setBackgroundResource", theme.backgroundResource(appearance.frostedGlass))
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
            val data = checkNotNull(courseData)
            val hideCompactDate =
                appearance.fontSize == NativeHomeWidgetFontSize.EXTRA_LARGE &&
                    variant.size == NativeHomeWidgetSize.SIZE_2X2
            // 日期节点同时承担标题的右侧约束，清空文本可释放宽度且不会破坏标题布局。
            views.setTextViewText(R.id.tv_widget_date, if (hideCompactDate) "" else data.date)
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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // 背景、标题和条目使用同一次捕获的外观并一起提交。旧式服务转换／
            // notify 会异步重发缓存的整页 RemoteViews，导致旧背景覆盖新主题。
            val factory: RemoteViewsService.RemoteViewsFactory = if (variant.kind == NativeHomeWidgetKind.COURSE) {
                CourseRemoteViewsFactory(context, variant, theme, typography, appearance.fontSize).apply { loadData() }
            } else {
                ExamRemoteViewsFactory(context, variant, theme, typography, appearance.fontSize).apply { loadData() }
            }
            val items = RemoteViews.RemoteCollectionItems.Builder()
                .setHasStableIds(true)
                .setViewTypeCount(factory.viewTypeCount)
            for (position in 0 until factory.count) {
                items.addItem(factory.getItemId(position), factory.getViewAt(position))
            }
            views.setRemoteAdapter(variant.listViewId, items.build())
        } else {
            setLegacyAdapter(context, views, appWidgetId, variant, theme, appearance.fontSize)
        }
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

    private fun setLegacyAdapter(
        context: Context,
        views: RemoteViews,
        appWidgetId: Int,
        variant: NativeWidgetVariant,
        theme: HomeWidgetThemeConfig,
        fontSize: NativeHomeWidgetFontSize,
    ) {
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
            putExtra(HomeWidgetRegistry.EXTRA_FONT_SIZE, fontSize.storageName)
            // RemoteViewsService 会按 Intent.filterEquals 缓存工厂；主题写进 data 才能让
            // 启动器在外观变化时放弃旧列表，避免新背景继续复用旧文字颜色。
            data = Uri.Builder()
                .scheme("shenliyuan-widget")
                .authority(variant.name.lowercase())
                .appendPath(appWidgetId.toString())
                .appendQueryParameter(
                    "appearance",
                    "${theme.resolvedTheme.storageName}-${fontSize.storageName}",
                )
                .build()
        }
        views.setRemoteAdapter(variant.listViewId, serviceIntent)
    }
}
