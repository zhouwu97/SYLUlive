package com.example.shenliyuan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * 考试小组件数据模型。
 *
 * JSON 结构（由 Flutter 端 shared_preferences 写入）：
 * ```json
 * [
 *   {
 *     "name": "高等数学",
 *     "date": "2026-06-24",
 *     "time": "08:00-10:00",
 *     "location": "综合楼A101"
 *   }
 * ]
 * ```
 */
data class WidgetExamData(
    val title: String = "考试日程",
    val textColor: String = "#333333",
    val exams: List<Exam> = emptyList(),
) {
    data class Exam(
        val name: String,
        val date: String,
        val time: String,
        val location: String,
        val countdown: String,
    )
}

/**
 * 从 Flutter shared_preferences 插件写入的 SharedPreferences 中读取数据。
 *
 * 存储路径：
 *   文件名:  FlutterSharedPreferences
 *   Key:    flutter.widget_exam_data
 */
object ExamDataReader {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY = "flutter.widget_exam_data"

    fun read(context: Context): WidgetExamData {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY, null)
            if (raw.isNullOrBlank()) return WidgetExamData()
            parse(raw, context)
        } catch (e: Exception) {
            android.util.Log.e("ExamDataReader", "读取考试数据失败", e)
            WidgetExamData()
        }
    }

    private fun parse(raw: String, context: Context): WidgetExamData {
        val arr = JSONArray(raw)
        val exams = mutableListOf<WidgetExamData.Exam>()
        for (i in 0 until arr.length()) {
            val c = arr.getJSONObject(i)
            val dateStr = c.optString("date", "")
            var dynamicCountdown = c.optString("countdown", "")
            try {
                if (dateStr.isNotEmpty()) {
                    val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
                    val examDate = sdf.parse(dateStr)
                    if (examDate != null) {
                        val today = java.util.Calendar.getInstance()
                        today.set(java.util.Calendar.HOUR_OF_DAY, 0)
                        today.set(java.util.Calendar.MINUTE, 0)
                        today.set(java.util.Calendar.SECOND, 0)
                        today.set(java.util.Calendar.MILLISECOND, 0)

                        val examCal = java.util.Calendar.getInstance()
                        examCal.time = examDate
                        examCal.set(java.util.Calendar.HOUR_OF_DAY, 0)
                        examCal.set(java.util.Calendar.MINUTE, 0)
                        examCal.set(java.util.Calendar.SECOND, 0)
                        examCal.set(java.util.Calendar.MILLISECOND, 0)

                        val diffDays = java.util.concurrent.TimeUnit.MILLISECONDS.toDays(
                            examCal.timeInMillis - today.timeInMillis
                        )

                        dynamicCountdown = when {
                            diffDays == 0L -> "今天"
                            diffDays == 1L -> "明天"
                            diffDays == 2L -> "后天"
                            diffDays > 2L -> "${diffDays}天后"
                            diffDays < 0L -> "已结束"
                            else -> ""
                        }
                    }
                }
            } catch (e: Exception) {
                // fallback to the countdown string provided by flutter if parsing fails
            }

            exams.add(WidgetExamData.Exam(
                name = c.optString("name", ""),
                date = dateStr,
                time = c.optString("time", ""),
                location = c.optString("location", ""),
                countdown = dynamicCountdown,
            ))
        }

        // 读取文本颜色配置（如果存在）
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val textColor = prefs.getString("flutter.widget_text_color", "#333333") ?: "#333333"

        return WidgetExamData(textColor = textColor, exams = exams)
    }
}
