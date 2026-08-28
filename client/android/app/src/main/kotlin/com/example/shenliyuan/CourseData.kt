package com.example.shenliyuan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * 小组件课程数据模型。
 *
 * Schema v2 JSON 结构（由 Flutter 端 shared_preferences 写入）：
 * ```json
 * {
 *   "schema_version": 2,
 *   "updated_at": "2026-08-28T09:12:00.000Z",
 *   "title": "沈理院课表",
 *   "semester_start": "2026-08-24",
 *   "academic_year": "2026-2027",
 *   "semester": 1,
 *   "courses": [
 *     {
 *       "name": "数字图像处理",
 *       "weekday": 5,
 *       "start_section": 2,
 *       "end_section": 3,
 *       "weeks": [1, 2, 3, 4],
 *       "location": "综A101",
 *       "teacher": "王辉宇",
 *       "color": "#3B82F6"
 *     }
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

    private val STARTS = listOf(
        "08:00", "08:55", "10:00", "10:55", "13:00", "13:55",
        "14:50", "15:45", "16:40", "17:35", "18:30", "19:25"
    )
    private val ENDS = listOf(
        "08:45", "09:40", "10:45", "11:40", "13:45", "14:40",
        "15:35", "16:30", "17:25", "18:20", "19:15", "20:10"
    )
    private val WEEKDAY_NAMES = arrayOf("", "一", "二", "三", "四", "五", "六", "日")

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

    fun parse(raw: String, nowCalendar: Calendar = Calendar.getInstance()): WidgetCourseData {
        val obj = JSONObject(raw)
        val version = if (obj.has("schema_version")) obj.optInt("schema_version", 1) else 1
        return when (version) {
            2 -> parseV2(obj, nowCalendar)
            1 -> parseV1(obj, nowCalendar)
            else -> WidgetCourseData()
        }
    }

    private fun parseV2(obj: JSONObject, calendar: Calendar): WidgetCourseData {
        val title = obj.optString("title", "沈理院课表")
        val semesterStartStr = obj.optString("semester_start", "")

        val dayOfWeek = calendar.get(Calendar.DAY_OF_WEEK)
        val currentWeekday = if (dayOfWeek == Calendar.SUNDAY) 7 else dayOfWeek - 1

        var academicWeek: Int? = null
        if (semesterStartStr.isNotBlank()) {
            try {
                val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
                val startDate = sdf.parse(semesterStartStr)
                if (startDate != null) {
                    val startCal = Calendar.getInstance().apply {
                        time = startDate
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    val todayCal = Calendar.getInstance().apply {
                        time = calendar.time
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    val diffDays = TimeUnit.MILLISECONDS.toDays(todayCal.timeInMillis - startCal.timeInMillis)
                    if (diffDays >= 0) {
                        academicWeek = (diffDays / 7).toInt() + 1
                    }
                }
            } catch (_: Exception) {
            }
        }

        val currentMonth = calendar.get(Calendar.MONTH) + 1
        val currentDay = calendar.get(Calendar.DAY_OF_MONTH)
        val weekName = WEEKDAY_NAMES.getOrElse(currentWeekday) { "" }
        val weekText = if (academicWeek != null) "第${academicWeek}周 " else ""
        val dateStr = "$currentMonth.$currentDay ${weekText}周$weekName"

        val currentMinutes = calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)

        val arr = obj.optJSONArray("courses") ?: JSONArray()
        val candidateCourses = mutableListOf<Triple<Int, WidgetCourseData.Course, Int>>()

        for (i in 0 until arr.length()) {
            val c = arr.getJSONObject(i)
            val weekday = c.optInt("weekday", 0)
            if (weekday != currentWeekday) continue

            val weeksArr = c.optJSONArray("weeks")
            if (academicWeek != null && weeksArr != null && weeksArr.length() > 0) {
                var containsWeek = false
                for (w in 0 until weeksArr.length()) {
                    if (weeksArr.optInt(w, -1) == academicWeek) {
                        containsWeek = true
                        break
                    }
                }
                if (!containsWeek) continue
            }

            val startSection = c.optInt("start_section", 1).coerceIn(1, 12)
            val endSection = c.optInt("end_section", startSection).coerceIn(1, 12)

            val startIdx = (startSection - 1).coerceIn(0, STARTS.size - 1)
            val endIdx = (endSection - 1).coerceIn(0, ENDS.size - 1)
            val timeStr = "${STARTS[startIdx]}-${ENDS[endIdx]}"

            val endParts = ENDS[endIdx].split(":")
            val endMinutes = endParts[0].toInt() * 60 + endParts[1].toInt()

            if (currentMinutes <= endMinutes) {
                val course = WidgetCourseData.Course(
                    name = c.optString("name", ""),
                    time = timeStr,
                    location = c.optString("location", ""),
                    teacher = c.optString("teacher", ""),
                    color = c.optString("color", "#6366F1"),
                )
                candidateCourses.add(Triple(startSection, course, endMinutes))
            }
        }

        candidateCourses.sortBy { it.first }
        val courses = candidateCourses.map { it.second }

        return WidgetCourseData(title = title, date = dateStr, courses = courses)
    }

    private fun parseV1(obj: JSONObject, calendar: Calendar): WidgetCourseData {
        val title = obj.optString("title", "沈理院课表")
        val date = obj.optString("date", "")
        val dateKey = obj.optString("date_key", "")
        val arr = obj.optJSONArray("courses") ?: JSONArray()

        val currentMonth = calendar.get(Calendar.MONTH) + 1
        val currentDay = calendar.get(Calendar.DAY_OF_MONTH)
        val datePrefix = "$currentMonth.$currentDay"
        val todayKey = "%04d-%02d-%02d".format(
            Locale.ROOT,
            calendar.get(Calendar.YEAR),
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
        val currentMinutes = calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)

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
                } catch (_: Exception) {
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
