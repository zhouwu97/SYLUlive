package com.example.shenliyuan

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService

class CourseWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        val variant = NativeWidgetVariant.fromName(
            intent.getStringExtra(HomeWidgetRegistry.EXTRA_VARIANT),
            NativeWidgetVariant.COURSE_2X2,
        )
        val fallbackAppearance = HomeWidgetAppearanceStore.read(
            applicationContext,
            NativeHomeWidgetKind.COURSE,
        )
        val resolvedTheme = intent
            .getStringExtra(HomeWidgetRegistry.EXTRA_RESOLVED_THEME)
            ?.let { NativeHomeWidgetTheme.fromStorage(it) }
            ?: fallbackAppearance.theme
        val fontSize = intent
            .getStringExtra(HomeWidgetRegistry.EXTRA_FONT_SIZE)
            ?.let { NativeHomeWidgetFontSize.fromStorage(it) }
            ?: fallbackAppearance.fontSize
        return CourseRemoteViewsFactory(
            applicationContext,
            variant,
            HomeWidgetThemeConfig.resolve(applicationContext, resolvedTheme),
            HomeWidgetTypography.resolve(variant.size, fontSize),
            fontSize,
        )
    }
}

class CourseRemoteViewsFactory(
    private val context: Context,
    private val variant: NativeWidgetVariant,
    private var theme: HomeWidgetThemeConfig,
    private var typography: HomeWidgetTypography,
    private var fontSize: NativeHomeWidgetFontSize,
) : RemoteViewsService.RemoteViewsFactory {
    private val courses = mutableListOf<WidgetCourseData.Course>()

    override fun onCreate() = Unit

    @Synchronized
    override fun onDataSetChanged() {
        // 启动器可能复用旧的 RemoteViewsFactory；每次刷新从原子快照读取完整外观，
        // 不继续使用创建服务时的 Intent extras 和主题对象。
        val appearance = HomeWidgetAppearanceStore.read(context, variant.kind)
        theme = HomeWidgetThemeConfig.resolve(context, appearance.theme)
        fontSize = appearance.fontSize
        typography = HomeWidgetTypography.resolve(variant.size, fontSize)
        loadData()
    }

    /** 整体 RemoteViews 更新时沿用调用方捕获的外观，只读取课程内容。 */
    @Synchronized
    internal fun loadData() {
        courses.clear()
        val data = CourseDataReader.read(context)
        courses.addAll(data.courses.take(variant.maxItems(fontSize)))
    }

    @Synchronized
    override fun onDestroy() = courses.clear()

    @Synchronized
    override fun getCount(): Int = courses.size

    @Synchronized
    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(
            context.packageName,
            variant.itemLayoutResource(fontSize),
        )
        if (position !in courses.indices) return views
        val course = courses[position]
        views.setTextViewText(R.id.tv_course_name, course.name.ifBlank { "未知课程" })
        val displayTime = if (fontSize == NativeHomeWidgetFontSize.EXTRA_LARGE) {
            course.time.replaceFirst("-", " - ")
        } else {
            course.time
        }
        views.setTextViewText(R.id.tv_course_time, displayTime)
        views.setTextViewText(R.id.tv_course_location, course.location)
        views.setTextViewText(R.id.tv_course_teacher, course.teacher)
        if (fontSize == NativeHomeWidgetFontSize.EXTRA_LARGE) {
            views.setTextViewText(R.id.tv_item_context, if (position == 0) "当前" else "接下来")
            views.setTextViewTextSize(
                R.id.tv_item_context,
                TypedValue.COMPLEX_UNIT_SP,
                typography.badgeSp,
            )
            views.setTextColor(R.id.tv_item_context, theme.secondaryTextColor)
        }
        views.setTextViewTextSize(
            R.id.tv_course_name,
            TypedValue.COMPLEX_UNIT_SP,
            typography.primarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_course_time,
            TypedValue.COMPLEX_UNIT_SP,
            typography.secondarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_course_location,
            TypedValue.COMPLEX_UNIT_SP,
            typography.secondarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_course_teacher,
            TypedValue.COMPLEX_UNIT_SP,
            typography.tertiarySp,
        )
        views.setViewVisibility(
            R.id.tv_course_location,
            if ((variant.size == NativeHomeWidgetSize.SIZE_4X2 ||
                    fontSize == NativeHomeWidgetFontSize.EXTRA_LARGE) &&
                course.location.isNotBlank()
            ) {
                View.VISIBLE
            } else {
                View.GONE
            },
        )
        views.setViewVisibility(
            R.id.tv_course_teacher,
            if ((variant.size == NativeHomeWidgetSize.SIZE_4X2 ||
                    fontSize == NativeHomeWidgetFontSize.EXTRA_LARGE) &&
                course.teacher.isNotBlank()
            ) {
                View.VISIBLE
            } else {
                View.GONE
            },
        )
        views.setTextColor(R.id.tv_course_name, theme.primaryTextColor)
        views.setTextColor(R.id.tv_course_time, theme.secondaryTextColor)
        views.setTextColor(R.id.tv_course_location, theme.mutedTextColor)
        views.setTextColor(R.id.tv_course_teacher, theme.mutedTextColor)

        val color = try {
            Color.parseColor(course.color)
        } catch (_: Exception) {
            theme.accentColor
        }
        views.setInt(R.id.iv_course_color, "setColorFilter", color)
        views.setOnClickFillInIntent(
            R.id.item_root_layout,
            Intent().putExtra("course_name", course.name),
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    // 同一工厂可能在普通／超大字号布局之间切换。
    override fun getViewTypeCount(): Int = 2
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = true
}
