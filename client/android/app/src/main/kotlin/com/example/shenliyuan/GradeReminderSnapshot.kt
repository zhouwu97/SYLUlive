package com.example.shenliyuan

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

data class GradeReminderSnapshot(
    val initialized: Boolean,
    val grades: List<GradeReminderItem>,
    val updatedAt: Long,
) {
    fun toJson(): JSONObject {
        val array = JSONArray()
        grades.forEach { array.put(it.toJson()) }
        return JSONObject()
            .put("initialized", initialized)
            .put("updatedAt", updatedAt)
            .put("grades", array)
    }

    fun diffFrom(old: GradeReminderSnapshot?): GradeReminderDiff {
        if (old == null || !old.initialized) {
            return GradeReminderDiff(emptyList(), baselineOnly = true)
        }

        val oldByKey = old.grades.associateBy { it.key }
        val changes = mutableListOf<GradeReminderChange>()

        grades.forEach { next ->
            val previous = oldByKey[next.key]
            if (previous == null) {
                if (next.hasEffectiveGrade()) {
                    changes += GradeReminderChange(null, next, "added")
                }
            } else if (
                (!previous.hasEffectiveGrade() && next.hasEffectiveGrade()) ||
                previous.grade.trim() != next.grade.trim() ||
                previous.gpa.orEmpty() != next.gpa.orEmpty() ||
                previous.fraction.orEmpty() != next.fraction.orEmpty()
            ) {
                if (
                    previous.hasEffectiveGrade() ||
                    next.hasEffectiveGrade() ||
                    !previous.gpa.isNullOrBlank() ||
                    !next.gpa.isNullOrBlank() ||
                    !previous.fraction.isNullOrBlank() ||
                    !next.fraction.isNullOrBlank()
                ) {
                    changes += GradeReminderChange(previous, next, "updated")
                }
            }
        }

        return GradeReminderDiff(changes.sortedBy { it.next.name })
    }

    companion object {
        fun empty(): GradeReminderSnapshot =
            GradeReminderSnapshot(true, emptyList(), System.currentTimeMillis())

        fun fromGrades(array: JSONArray): GradeReminderSnapshot {
            val items = buildList {
                for (index in 0 until array.length()) {
                    val item = fromGradeJson(array.optJSONObject(index) ?: continue)
                    if (item.key.isNotBlank()) add(item)
                }
            }.sortedBy { it.key }
            return GradeReminderSnapshot(true, items, System.currentTimeMillis())
        }

        fun fromJson(raw: String?): GradeReminderSnapshot? {
            if (raw.isNullOrBlank()) return null
            return runCatching {
                val json = JSONObject(raw)
                val array = json.optJSONArray("grades") ?: JSONArray()
                val items = buildList {
                    for (index in 0 until array.length()) {
                        GradeReminderItem.fromJson(array.optJSONObject(index) ?: continue)
                            ?.let(::add)
                    }
                }
                GradeReminderSnapshot(
                    initialized = json.optBoolean("initialized", false),
                    grades = items,
                    updatedAt = json.optLong("updatedAt", System.currentTimeMillis()),
                )
            }.getOrNull()
        }

        fun fromJsonObject(json: JSONObject?): GradeReminderSnapshot? {
            if (json == null) return null
            return fromJson(json.toString())
        }

        private fun fromGradeJson(json: JSONObject): GradeReminderItem {
            val name = json.optStringOrNull("name").orEmpty()
            val credits = normalizeNumber(json.opt("credits"))
            val examType = blankToNull(json.optStringOrNull("exam_type"))
            val key = stableKey(json, name, credits, examType)
            return GradeReminderItem(
                key = key,
                name = name,
                grade = json.optStringOrNull("grade") ?: "--",
                gpa = blankToNull(normalizeNumber(json.opt("gpa"))),
                fraction = blankToNull(normalizeNumber(json.opt("fraction"))),
                credits = credits.ifBlank { "0" },
                examType = examType,
                isDegree = json.optBoolean("is_degree", false) ||
                    json.optStringOrNull("is_degree") == "1" ||
                    json.optStringOrNull("is_degree") == "是",
            )
        }

        private fun stableKey(
            json: JSONObject,
            name: String,
            credits: String,
            examType: String?,
        ): String {
            val studentGradeId = json.optStringOrNull("student_grade_id").orEmpty()
            if (studentGradeId.isNotEmpty()) return "student:$studentGradeId"
            val classId = json.optStringOrNull("class_id").orEmpty()
            if (classId.isNotEmpty()) return "class:$classId"
            val courseId = json.optStringOrNull("course_id").orEmpty()
            if (courseId.isNotEmpty()) return "course:$courseId"
            val courseCode = json.optStringOrNull("course_code").orEmpty()
            if (courseCode.isNotEmpty() && name.isNotEmpty()) {
                return "code:$courseCode|$name"
            }
            if (name.isNotEmpty()) return "name:$name|$credits|${examType.orEmpty()}"
            return ""
        }

        private fun normalizeNumber(value: Any?): String {
            val text = value?.toString()?.trim().orEmpty()
            if (text.isBlank() || text == "null") return ""
            val asDouble = text.toDoubleOrNull() ?: return text
            val asLong = asDouble.toLong()
            return if (asDouble == asLong.toDouble()) asLong.toString() else text
        }

        private fun blankToNull(value: String?): String? {
            val text = value?.trim().orEmpty()
            return text.ifBlank { null }
        }
    }
}

data class GradeReminderItem(
    val key: String,
    val name: String,
    val grade: String,
    val gpa: String?,
    val fraction: String?,
    val credits: String,
    val examType: String?,
    val isDegree: Boolean,
) {
    fun hasEffectiveGrade(): Boolean {
        val text = grade.trim()
        if (text.isBlank()) return false
        return text !in setOf("--", "未录入", "暂无", "无", "null", "NULL", "缓考")
    }

    fun displayGrade(): String = grade.trim().ifBlank { "--" }

    fun toJson(): JSONObject = JSONObject()
        .put("key", key)
        .put("name", name)
        .put("grade", grade)
        .put("gpa", gpa)
        .put("fraction", fraction)
        .put("credits", credits)
        .put("examType", examType)
        .put("isDegree", isDegree)

    companion object {
        fun fromJson(json: JSONObject): GradeReminderItem? {
            val key = json.optString("key")
            if (key.isBlank()) return null
            return GradeReminderItem(
                key = key,
                name = json.optString("name"),
                grade = json.optString("grade"),
                gpa = json.optStringOrNull("gpa"),
                fraction = json.optStringOrNull("fraction"),
                credits = json.optString("credits", "0"),
                examType = json.optStringOrNull("examType"),
                isDegree = json.optBoolean("isDegree", false),
            )
        }
    }
}

data class GradeReminderChange(
    val previous: GradeReminderItem?,
    val next: GradeReminderItem,
    val type: String,
) {
    fun summary(): String = "${next.name}: ${previous?.displayGrade() ?: "--"} -> ${next.displayGrade()}"

    fun toHashJson(): JSONObject = JSONObject()
        .put("type", type)
        .put("key", next.key)
        .put("name", next.name)
        .put("oldGrade", previous?.displayGrade().orEmpty())
        .put("newGrade", next.displayGrade())
        .put("oldGpa", previous?.gpa.orEmpty())
        .put("newGpa", next.gpa.orEmpty())
        .put("oldFraction", previous?.fraction.orEmpty())
        .put("newFraction", next.fraction.orEmpty())
}

data class GradeReminderDiff(
    val changes: List<GradeReminderChange>,
    val baselineOnly: Boolean = false,
) {
    val hasChanges: Boolean get() = changes.isNotEmpty()

    fun changeHash(): String {
        if (changes.isEmpty()) return ""
        val array = JSONArray()
        changes.forEach { array.put(it.toHashJson()) }
        return sha1(array.toString())
    }

    private fun sha1(value: String): String {
        val digest = MessageDigest.getInstance("SHA-1")
            .digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }
}

private fun JSONObject.optStringOrNull(name: String): String? {
    if (!has(name) || isNull(name)) return null
    val text = optString(name).trim()
    return text.ifBlank { null }
}
