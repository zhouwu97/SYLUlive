package com.example.shenliyuan

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
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

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            val views = RemoteViews(context.packageName, R.layout.course_schedule_widget)

            // ── 读取 Flutter 端写入的数据 ──
            val prefs = HomeWidgetPlugin.getData(context)
            val title = prefs.getString(KEY_TITLE, "沈理院课表") ?: "沈理院课表"
            val date = prefs.getString(KEY_DATE, "") ?: ""
            val content = prefs.getString(KEY_CONTENT, "") ?: ""
            val isEmpty = prefs.getBoolean(KEY_EMPTY, true)

            // ── 更新标题和日期 ──
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_date, date)

            // ── 更新课程内容 ──
            if (isEmpty) {
                // 显示颜文字无课提示
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                views.setViewVisibility(R.id.widget_courses, View.GONE)
            } else {
                // 显示课程列表
                views.setViewVisibility(R.id.widget_empty, View.GONE)
                views.setViewVisibility(R.id.widget_courses, View.VISIBLE)
                // 移除旧的课程条目
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

            // ── 点击跳转：PendingIntent → 显式启动 MainActivity ──
            // 之前的隐式 Intent(ACTION_VIEW) 可能在部分设备上无法准确路由到本应用，这里改为显式指定组件
            val clickIntent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                data = Uri.parse("timetable://home")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            
            // 兼容高版本 Android 的 PendingIntent 标志
            val flags = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            
            val pendingIntent = PendingIntent.getActivity(
                context,
                appWidgetId,
                clickIntent,
                flags
            )
            // 给整个小部件设置点击事件
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            // ── 应用到 widget ──
            appWidgetManager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "更新 Widget 失败", e)
            // 失败时也更新一个基本的 fallback 视图，防止卡在“载入窗口小部件时出现问题”
            val fallbackViews = RemoteViews(context.packageName, R.layout.course_schedule_widget)
            fallbackViews.setTextViewText(R.id.widget_title, "沈理院课表(错误)")
            fallbackViews.setTextViewText(R.id.widget_date, "加载失败")
            fallbackViews.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            fallbackViews.setViewVisibility(R.id.widget_courses, View.GONE)
            appWidgetManager.updateAppWidget(appWidgetId, fallbackViews)
        }
    }
}
