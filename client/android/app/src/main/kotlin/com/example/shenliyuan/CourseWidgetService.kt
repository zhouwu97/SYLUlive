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
        return CourseRemoteViewsFactory(
            applicationContext,
            NativeWidgetVariant.fromName(
                intent.getStringExtra(HomeWidgetRegistry.EXTRA_VARIANT),
                NativeWidgetVariant.COURSE_2X2,
            ),
        )
    }
}

class CourseRemoteViewsFactory(
    private val context: Context,
    private val variant: NativeWidgetVariant,
) : RemoteViewsService.RemoteViewsFactory {
    private val courses = mutableListOf<WidgetCourseData.Course>()
    private lateinit var theme: HomeWidgetThemeConfig
    private lateinit var typography: HomeWidgetTypography

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        courses.clear()
        val data = CourseDataReader.read(context)
        courses.addAll(data.courses.take(variant.maxItems))
        val appearance = HomeWidgetAppearanceStore.read(context, NativeHomeWidgetKind.COURSE)
        theme = HomeWidgetThemeConfig.resolve(context, appearance.theme)
        typography = HomeWidgetTypography.resolve(variant.size, appearance.fontSize)
    }

    override fun onDestroy() = courses.clear()

    override fun getCount(): Int = courses.size

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, variant.itemLayoutResource)
        if (position !in courses.indices) return views
        val course = courses[position]
        views.setTextViewText(R.id.tv_course_name, course.name.ifBlank { "未知课程" })
        views.setTextViewText(R.id.tv_course_time, course.time)
        views.setTextViewText(R.id.tv_course_location, course.location)
        views.setTextViewText(R.id.tv_course_teacher, course.teacher)
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
            if (variant.size == NativeHomeWidgetSize.SIZE_4X2 && course.location.isNotBlank()) {
                View.VISIBLE
            } else {
                View.GONE
            },
        )
        views.setViewVisibility(
            R.id.tv_course_teacher,
            if (variant.size == NativeHomeWidgetSize.SIZE_4X2 && course.teacher.isNotBlank()) {
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
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = true
}
