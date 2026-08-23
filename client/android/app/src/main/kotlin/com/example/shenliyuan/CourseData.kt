package com.example.shenliyuan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * 小组件课程数据模型。
 *
 * JSON 结构（由 Flutter 端 shared_preferences 写入）：
 * ```json
 * {
 *   "title": "沈理院课表",
 *   "date": "5.21 第12周 周三",
 *   "courses": [
 *     { "name": "高等数学", "time": "08:00-08:45", "location": "综A101" }
 *   ]
 * }
 * ```
 */
data class WidgetCourseData(
    val title: String = "沈理院课表",
    val date: String = "",
    val courses: List<Course> = emptyList(),
) {
    data class Course(
        val name: String,
        val time: String,
        val location: String,
        val teacher: String,
        val color: String,
    )
}

/**
 * 从 Flutter shared_preferences 插件写入的 SharedPreferences 中读取数据。
 *
 * 存储路径：
 *   文件名:  FlutterSharedPreferences
 *   Key:    flutter.widget_course_data
 */
object CourseDataReader {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY = "flutter.widget_course_data"

    fun read(context: Context): WidgetCourseData {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY, null)
            if (raw.isNullOrBlank()) return WidgetCourseData()
            parse(raw)
        } catch (e: Exception) {
            android.util.Log.e("CourseDataReader", "读取课程数据失败", e)
            WidgetCourseData()
        }
    }

    fun hasData(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.contains(KEY)
    }

    private fun parse(raw: String): WidgetCourseData {
        val obj = JSONObject(raw)
        if (obj.has("schema_version") && obj.optInt("schema_version", -1) != 1) {
            return WidgetCourseData()
        }
        val title = obj.optString("title", "沈理院课表")
        val date = obj.optString("date", "")
        val dateKey = obj.optString("date_key", "")
        val arr = obj.optJSONArray("courses") ?: JSONArray()

        val calendar = java.util.Calendar.getInstance()
        val currentMonth = calendar.get(java.util.Calendar.MONTH) + 1
        val currentDay = calendar.get(java.util.Calendar.DAY_OF_MONTH)
        val datePrefix = "$currentMonth.$currentDay"
        val todayKey = "%04d-%02d-%02d".format(
            java.util.Locale.ROOT,
            calendar.get(java.util.Calendar.YEAR),
            currentMonth,
            currentDay,
        )
        val isToday = if (dateKey.isNotEmpty()) {
            dateKey == todayKey
        } else {
            date.startsWith(datePrefix) || date.startsWith("0$currentMonth.$currentDay")
        }
        if (dateKey.isNotEmpty() && !isToday) {
            return WidgetCourseData(title = title, date = "暂无今日数据")
        }
        val currentMinutes = calendar.get(java.util.Calendar.HOUR_OF_DAY) * 60 + calendar.get(java.util.Calendar.MINUTE)

        val courses = mutableListOf<WidgetCourseData.Course>()
        for (i in 0 until arr.length()) {
            val c = arr.getJSONObject(i)
            val timeStr = c.optString("time", "")

            var hasEnded = false
            if (isToday) {
                try {
                    if (timeStr.contains("-")) {
                        val endTimeStr = timeStr.split("-")[1].trim()
                        val parts = endTimeStr.split(":")
                        if (parts.size == 2) {
                            val endHour = parts[0].toInt()
                            val endMinute = parts[1].toInt()
                            val endMinutes = endHour * 60 + endMinute
                            if (currentMinutes > endMinutes) {
                                hasEnded = true
                            }
                        }
                    }
                } catch (e: Exception) {
                    // Ignore parse errors
                }
            }

            if (!hasEnded) {
                courses.add(WidgetCourseData.Course(
                    name = c.optString("name", ""),
                    time = timeStr,
                    location = c.optString("location", ""),
                    teacher = c.optString("teacher", ""),
                    color = c.optString("color", "#6366F1"),
                ))
            }
        }
        return WidgetCourseData(title = title, date = date, courses = courses)
    }
}
