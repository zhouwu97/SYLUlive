package com.example.shenliyuan

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore

object AcademicArchiveStore {
    fun save(context: Context, name: String, content: String, folder: String): Map<String, Any> {
        require(name.isNotBlank() && name != "." && name != ".." &&
            !name.any { it == '/' || it == '\\' || it.isISOControl() })
        require(folder == "课表存档" || folder == "考试存档")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return mapOf("legacy" to true)
        val relative = "${Environment.DIRECTORY_DOWNLOADS}/沈理校园/$folder/"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("无法创建公共下载存档")
        try {
            val stream = resolver.openOutputStream(uri) ?: error("无法写入下载存档")
            stream.use { it.write(content.toByteArray(Charsets.UTF_8)) }
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            check(resolver.update(uri, published, null, null) == 1)
            val actualName = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                null, null, null)?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else name } ?: name
            return mapOf("savedPath" to "$relative$actualName", "uri" to uri.toString())
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }
}
