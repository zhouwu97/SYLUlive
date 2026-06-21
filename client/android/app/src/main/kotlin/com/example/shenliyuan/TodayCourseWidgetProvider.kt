package com.example.shenliyuan

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

class TodayCourseWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = buildRemoteViews(context, appWidgetId)
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.course_list_view)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {}

    companion object {
        fun buildRemoteViews(context: Context, appWidgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_today_course)

            // ── 标题：优先读用户自定义名，否则 fallback 到课表数据内的默认名 ──
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val customTitle = prefs.getString("flutter.widget_title", null)
            val wkData = CourseDataReader.read(context)
            val title = customTitle ?: wkData.title
            views.setTextViewText(R.id.tv_widget_title, title)
            views.setTextViewText(R.id.tv_widget_date, wkData.date)

            try {
                val parsedTextColor = android.graphics.Color.parseColor(wkData.textColor)
                views.setTextColor(R.id.tv_widget_title, parsedTextColor)
                views.setTextColor(R.id.tv_widget_date, parsedTextColor)
            } catch (e: Exception) {
                android.util.Log.e("CourseWidget", "Failed to parse text color for title", e)
            }

            // ── 深度链接：点击 → 直达课表页 ──
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                action = "com.example.shenliyuan.ACTION_WIDGET_TIMETABLE"
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            val launchPi = PendingIntent.getActivity(
                context, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.empty_view, launchPi)
            // Make the entire widget background clickable to launch the app
            views.setOnClickPendingIntent(android.R.id.background, launchPi)

            // ── ListView 适配器 + 点击模板 ──
            val serviceIntent = Intent(context, CourseWidgetService::class.java)
            serviceIntent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            serviceIntent.data = Uri.parse(serviceIntent.toUri(Intent.URI_INTENT_SCHEME))
            views.setRemoteAdapter(R.id.course_list_view, serviceIntent)
            views.setEmptyView(R.id.course_list_view, R.id.empty_view)

            val templatePi = PendingIntent.getActivity(
                context, 1, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            views.setPendingIntentTemplate(R.id.course_list_view, templatePi)

            return views
        }
    }
}
