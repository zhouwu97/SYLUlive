package com.example.shenliyuan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

class CourseDataReaderTest {

    @Test
    fun `Schema v2 动态根据开学日期计算教学周并过滤当天课程`() {
        val json = """
        {
          "schema_version": 2,
          "title": "沈理院课表",
          "semester_start": "2026-08-24",
          "academic_year": "2026-2027",
          "semester": 1,
          "courses": [
            {
              "name": "数字图像处理",
              "weekday": 5,
              "start_section": 2,
              "end_section": 3,
              "weeks": [1, 2, 3, 4],
              "location": "综A427",
              "teacher": "王辉宇",
              "color": "#3B82F6"
            },
            {
              "name": "大学物理",
              "weekday": 5,
              "start_section": 6,
              "end_section": 7,
              "weeks": [2, 3, 4],
              "location": "综B101",
              "teacher": "李老师",
              "color": "#10B981"
            },
            {
              "name": "高等数学",
              "weekday": 4,
              "start_section": 1,
              "end_section": 2,
              "weeks": [1, 2, 3],
              "location": "综A101",
              "teacher": "张老师",
              "color": "#EF4444"
            }
          ]
        }
        """.trimIndent()

        // 2026-08-28 08:00 (周五，第1周，08:00 在第2节 08:55-09:40 之前)
        val cal = Calendar.getInstance().apply {
            set(2026, Calendar.AUGUST, 28, 8, 0, 0)
        }

        val data = CourseDataReader.parse(json, cal)
        assertEquals("沈理院课表", data.title)
        assertEquals("8.28 第1周 周五", data.date)
        // 只有“数字图像处理”匹配第1周周五，“大学物理”为第2-4周，“高等数学”为周四
        assertEquals(1, data.courses.size)
        assertEquals("数字图像处理", data.courses[0].name)
        assertEquals("08:55-10:45", data.courses[0].time)
        assertEquals("综A427", data.courses[0].location)
        assertEquals("王辉宇", data.courses[0].teacher)
    }

    @Test
    fun `Schema v2 当天已结束的课程节次自动过滤`() {
        val json = """
        {
          "schema_version": 2,
          "title": "沈理院课表",
          "semester_start": "2026-08-24",
          "courses": [
            {
              "name": "早八课程",
              "weekday": 5,
              "start_section": 1,
              "end_section": 1,
              "weeks": [1],
              "location": "综A101",
              "teacher": "张老师",
              "color": "#3B82F6"
            },
            {
              "name": "下午课程",
              "weekday": 5,
              "start_section": 5,
              "end_section": 6,
              "weeks": [1],
              "location": "综A102",
              "teacher": "李老师",
              "color": "#10B981"
            }
          ]
        }
        """.trimIndent()

        // 2026-08-28 10:00 (第1节 08:00-08:45 已结束，第5-6节 13:00-14:40 未结束)
        val cal = Calendar.getInstance().apply {
            set(2026, Calendar.AUGUST, 28, 10, 0, 0)
        }

        val data = CourseDataReader.parse(json, cal)
        assertEquals(1, data.courses.size)
        assertEquals("下午课程", data.courses[0].name)
        assertEquals("13:00-14:40", data.courses[0].time)
    }

    @Test
    fun `Schema v2 无开学日期或开学前正常回退`() {
        val json = """
        {
          "schema_version": 2,
          "title": "沈理院课表",
          "courses": [
            {
              "name": "常驻课程",
              "weekday": 5,
              "start_section": 1,
              "end_section": 2,
              "weeks": [],
              "location": "综A101",
              "teacher": "张老师",
              "color": "#3B82F6"
            }
          ]
        }
        """.trimIndent()

        val cal = Calendar.getInstance().apply {
            set(2026, Calendar.AUGUST, 28, 7, 0, 0)
        }

        val data = CourseDataReader.parse(json, cal)
        assertEquals("8.28 周五", data.date)
        assertEquals(1, data.courses.size)
        assertEquals("常驻课程", data.courses[0].name)
    }

    @Test
    fun `Schema v1 兼容性 跨日返回暂无今日数据，当天正常解析`() {
        val jsonYesterday = """
        {
          "schema_version": 1,
          "title": "沈理院课表",
          "date": "8.27 第1周 周四",
          "date_key": "2026-08-27",
          "courses": [
            {
              "name": "旧课程",
              "time": "08:00-08:45",
              "location": "综A101",
              "teacher": "张老师",
              "color": "#3B82F6"
            }
          ]
        }
        """.trimIndent()

        val calToday = Calendar.getInstance().apply {
            set(2026, Calendar.AUGUST, 28, 8, 0, 0)
        }

        val staleData = CourseDataReader.parse(jsonYesterday, calToday)
        assertEquals("暂无今日数据", staleData.date)
        assertTrue(staleData.courses.isEmpty())

        val jsonToday = """
        {
          "schema_version": 1,
          "title": "沈理院课表",
          "date": "8.28 第1周 周五",
          "date_key": "2026-08-28",
          "courses": [
            {
              "name": "今日课程",
              "time": "08:55-09:40",
              "location": "综A101",
              "teacher": "张老师",
              "color": "#3B82F6"
            }
          ]
        }
        """.trimIndent()

        val todayData = CourseDataReader.parse(jsonToday, calToday)
        assertEquals("8.28 第1周 周五", todayData.date)
        assertEquals(1, todayData.courses.size)
        assertEquals("今日课程", todayData.courses[0].name)
    }
}
