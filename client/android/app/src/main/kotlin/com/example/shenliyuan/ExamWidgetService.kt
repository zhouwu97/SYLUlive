package com.example.shenliyuan

import android.content.Context
import android.content.Intent
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService

class ExamWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        val variant = NativeWidgetVariant.fromName(
            intent.getStringExtra(HomeWidgetRegistry.EXTRA_VARIANT),
            NativeWidgetVariant.EXAM_2X2,
        )
        val fallbackAppearance = HomeWidgetAppearanceStore.read(
            applicationContext,
            NativeHomeWidgetKind.EXAM,
        )
        val resolvedTheme = intent
            .getStringExtra(HomeWidgetRegistry.EXTRA_RESOLVED_THEME)
            ?.let { NativeHomeWidgetTheme.fromStorage(it) }
            ?: fallbackAppearance.theme
        val fontSize = intent
            .getStringExtra(HomeWidgetRegistry.EXTRA_FONT_SIZE)
            ?.let { NativeHomeWidgetFontSize.fromStorage(it) }
            ?: fallbackAppearance.fontSize
        return ExamRemoteViewsFactory(
            applicationContext,
            variant,
            HomeWidgetThemeConfig.resolve(applicationContext, resolvedTheme),
            HomeWidgetTypography.resolve(variant.size, fontSize),
            fontSize,
        )
    }
}

class ExamRemoteViewsFactory(
    private val context: Context,
    private val variant: NativeWidgetVariant,
    private val theme: HomeWidgetThemeConfig,
    private val typography: HomeWidgetTypography,
    private val fontSize: NativeHomeWidgetFontSize,
) : RemoteViewsService.RemoteViewsFactory {
    private val exams = mutableListOf<WidgetExamData.Exam>()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        exams.clear()
        exams.addAll(
            ExamDataReader.read(context).exams.take(variant.maxItems(fontSize)),
        )
    }

    override fun onDestroy() = exams.clear()

    override fun getCount(): Int = exams.size

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(
            context.packageName,
            variant.itemLayoutResource(fontSize),
        )
        if (position !in exams.indices) return views
        val exam = exams[position]
        views.setTextViewText(R.id.tv_exam_name, exam.name)
        views.setTextViewText(R.id.tv_exam_date, exam.date)
        views.setTextViewText(R.id.tv_exam_time, exam.time)
        views.setTextViewText(R.id.tv_exam_location, exam.location)
        views.setTextViewText(R.id.tv_exam_countdown, exam.countdown)
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
            R.id.tv_exam_name,
            TypedValue.COMPLEX_UNIT_SP,
            typography.primarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_exam_date,
            TypedValue.COMPLEX_UNIT_SP,
            typography.secondarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_exam_time,
            TypedValue.COMPLEX_UNIT_SP,
            typography.secondarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_exam_location,
            TypedValue.COMPLEX_UNIT_SP,
            typography.tertiarySp,
        )
        views.setTextViewTextSize(
            R.id.tv_exam_countdown,
            TypedValue.COMPLEX_UNIT_SP,
            typography.badgeSp,
        )
        views.setViewVisibility(
            R.id.tv_exam_countdown,
            if (exam.countdown.isBlank()) View.GONE else View.VISIBLE,
        )
        views.setViewVisibility(
            R.id.tv_exam_location,
            if ((variant.size == NativeHomeWidgetSize.SIZE_4X2 ||
                    fontSize == NativeHomeWidgetFontSize.EXTRA_LARGE) &&
                exam.location.isNotBlank()
            ) {
                View.VISIBLE
            } else {
                View.GONE
            },
        )
        views.setTextColor(R.id.tv_exam_name, theme.primaryTextColor)
        views.setTextColor(R.id.tv_exam_date, theme.secondaryTextColor)
        views.setTextColor(R.id.tv_exam_time, theme.secondaryTextColor)
        views.setTextColor(R.id.tv_exam_location, theme.mutedTextColor)
        views.setTextColor(R.id.tv_exam_countdown, theme.accentColor)
        views.setInt(R.id.iv_exam_color, "setColorFilter", theme.accentColor)

        views.setOnClickFillInIntent(
            R.id.item_root_layout,
            Intent().apply {
                putExtra("exam_name", exam.name)
                putExtra("exam_date", exam.date)
            },
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = true
}
