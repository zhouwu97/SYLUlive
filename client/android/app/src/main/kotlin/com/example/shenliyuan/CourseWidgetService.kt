package com.example.shenliyuan

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService

/**
 * RemoteViewsService — ListView 的跨进程数据网关。
 * 桌面系统通过此 Service 获取 RemoteViewsFactory。
 */
class CourseWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return CourseRemoteViewsFactory(applicationContext)
    }
}

/**
 * RemoteViewsFactory — 相当于 ListView 的 Adapter。
 *
 * 在 [onDataSetChanged] 中从 FlutterSharedPreferences 读取 JSON 课程数据，
 * 在 [getViewAt] 中将每门课绑定到 RemoteViews。
 */
class CourseRemoteViewsFactory(
    private val context: Context,
) : RemoteViewsService.RemoteViewsFactory {

    private val courses = mutableListOf<WidgetCourseData.Course>()
    private var textColorHex = "#333333"

    override fun onCreate() {}

    /**
     * 系统在以下时机调用此方法：
     * 1. Widget 首次添加到桌面
     * 2. [AppWidgetManager.notifyAppWidgetViewDataChanged] 被调用
     *
     * 此方法运行在 Binder 线程，可安全执行 I/O。
     */
    override fun onDataSetChanged() {
        courses.clear()
        try {
            val data = CourseDataReader.read(context)
            courses.addAll(data.courses)
            textColorHex = data.textColor
            android.util.Log.d("CourseWidget", "onDataSetChanged: ${courses.size} 门课")
        } catch (e: Exception) {
            android.util.Log.e("CourseWidget", "onDataSetChanged 崩溃", e)
        }
    }

    override fun onDestroy() {
        courses.clear()
    }

    override fun getCount(): Int = courses.size

    override fun getViewAt(position: Int): RemoteViews {
        android.util.Log.d("CourseWidget", "getViewAt($position) 开始, 共 ${courses.size} 门课")

        return try {
            val views = RemoteViews(context.packageName, R.layout.widget_today_course_item)

            if (position < courses.size) {
                val course = courses[position]
                val name = course.name.ifBlank { "未知课程" }
                val time = course.time.ifBlank { "" }
                var loc = course.location.ifBlank { "" }

                if (course.teacher.isNotBlank()) {
                    loc = if (loc.isNotBlank()) "$loc · ${course.teacher}" else course.teacher
                }

                android.util.Log.d("CourseWidget", "  渲染: $name | $time | $loc")
                views.setTextViewText(R.id.tv_course_name, name)
                views.setTextViewText(R.id.tv_course_time, time)
                views.setTextViewText(R.id.tv_course_location, loc)

                try {
                    val parsedTextColor = android.graphics.Color.parseColor(textColorHex)
                    views.setTextColor(R.id.tv_course_name, parsedTextColor)
                    views.setTextColor(R.id.tv_course_time, parsedTextColor)
                    views.setTextColor(R.id.tv_course_location, parsedTextColor)
                } catch (e: Exception) {
                    android.util.Log.e("CourseWidget", "Text color parse failed", e)
                }

                try {
                    val courseColor = android.graphics.Color.parseColor(course.color)
                    views.setInt(R.id.iv_course_color, "setColorFilter", courseColor)
                } catch (e: Exception) {
                    views.setInt(R.id.iv_course_color, "setColorFilter", android.graphics.Color.parseColor("#6366F1"))
                }

                val fillIntent = Intent().apply {
                    putExtra("course_name", name)
                }
                views.setOnClickFillInIntent(R.id.item_root_layout, fillIntent)
                android.util.Log.d("CourseWidget", "  getViewAt($position) 完成")
            }

            views
        } catch (e: Exception) {
            android.util.Log.e("CourseWidget", "getViewAt($position) 崩溃!", e)
            // 返回一个最简的 fallback item，避免整个 ListView 挂掉
            RemoteViews(context.packageName, R.layout.widget_today_course_item)
                .also { it.setTextViewText(R.id.tv_course_name, "加载失败") }
        }
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = true
}
