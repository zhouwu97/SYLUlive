package com.example.shenliyuan

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.LinearLayout
import android.widget.RemoteViews
import android.widget.TextView
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * 课表桌面小部件 Provider
 *
 * 数据由 Flutter 端通过 [HomeWidgetPlugin.saveWidgetData] 写入 SharedPreferences，
 * 原生端在 [onUpdate] 时读取并渲染 UI。
 * 点击整个小部件通过 PendingIntent 唤醒 App 并传入 timetable://home URI。
 */
class CourseScheduleWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "CourseScheduleWidget"

        // 与 Flutter 端 HomeWidget.saveWidgetData 的 key 保持一致
        private const val KEY_TITLE = "widget_title"
        private const val KEY_DATE = "widget_date"
        private const val KEY_CONTENT = "widget_content"
        private const val KEY_EMPTY = "widget_empty"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        // Widget 被移除，无需额外清理；SharedPreferences 数据由 Flutter 端管理
    }

    override fun onEnabled(context: Context) {
        // 首次添加 widget 时调用
    }

    override fun onDisabled(context: Context) {
        // 最后一个 widget 被移除时调用
    }

    /**
     * 更新单个 widget 实例的 UI
     */
    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val views = RemoteViews(context.packageName, R.layout.course_schedule_widget)

        // ── 读取 Flutter 端写入的数据 ──
        val prefs = HomeWidgetPlugin.getData(context)
        val title = prefs.getString(KEY_TITLE, "沈理院课表")
        val date = prefs.getString(KEY_DATE, "")
        val content = prefs.getString(KEY_CONTENT, "")
        val isEmpty = prefs.getBoolean(KEY_EMPTY, true)

        // ── 更新标题和日期 ──
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_date, date)

        // ── 更新课程内容 ──
        val contentContainer = views // 不再使用 findViewById，直接操作 RemoteViews
        if (isEmpty) {
            // 显示颜文字无课提示
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setViewVisibility(R.id.widget_courses, View.GONE)
        } else {
            // 显示课程列表
            views.setViewVisibility(R.id.widget_empty, View.GONE)
            views.setViewVisibility(R.id.widget_courses, View.VISIBLE)
            // 移除旧的课程条目（通过 removeAllViews）
            views.removeAllViews(R.id.widget_courses)
            // 逐条课程添加
            val courses = content.split("\n").filter { it.isNotBlank() }
            for (course in courses) {
                val itemView = RemoteViews(context.packageName, R.layout.widget_course_item)
                // 按 | 分割课程信息：名称|时间|地点
                val parts = course.split("|")
                itemView.setTextViewText(R.id.course_name, parts.getOrElse(0) { course })
                itemView.setTextViewText(R.id.course_time, parts.getOrElse(1) { "" })
                itemView.setTextViewText(R.id.course_location, parts.getOrElse(2) { "" })
                views.addView(R.id.widget_courses, itemView)
            }
        }

        // ── 点击跳转：PendingIntent → timetable://home ──
        val clickIntent = Intent(Intent.ACTION_VIEW, Uri.parse("timetable://home")).apply {
            // 确保唤醒的是当前 App 的 MainActivity
            setPackage(context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            appWidgetId,
            clickIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

        // ── 应用到 widget ──
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
