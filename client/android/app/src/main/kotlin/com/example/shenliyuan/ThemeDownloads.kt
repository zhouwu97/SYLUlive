package com.example.shenliyuan

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.io.ByteArrayOutputStream

internal object ThemeDownloads {
    const val path = "Download/沈理校园/主题/"
    private const val maxBytes = 48 * 1024 * 1024
    private const val mime = "application/vnd.sylulive.theme+zip"
    private fun preferences(context: Context) =
        context.getSharedPreferences("theme_downloads", Context.MODE_PRIVATE)

    fun grant(context: Context, uri: Uri) {
        require(uri.authority == "com.android.externalstorage.documents" &&
            DocumentsContract.getTreeDocumentId(uri) == "primary:Download/沈理校园/主题")
        context.contentResolver.takePersistableUriPermission(
            uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        preferences(context).edit().putString("tree", uri.toString()).apply()
    }

    fun list(context: Context): List<Map<String, String>> {
        val resolver = context.contentResolver
        val tree = preferences(context).getString("tree", null)?.let(Uri::parse)
            ?.takeIf { candidate -> resolver.persistedUriPermissions.any { it.uri == candidate && it.isReadPermission } }
        val files = mutableListOf<Map<String, String>>()
        if (tree != null) {
            val id = DocumentsContract.getTreeDocumentId(tree)
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val name = cursor.getString(1)
                    if (!name.endsWith(".sltheme", ignoreCase = true)) continue
                    val file = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                    files.add(mapOf("uri" to file.toString(), "name" to name))
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val downloads = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            resolver.query(downloads, arrayOf("_id", "_display_name"),
                "relative_path = ? AND is_pending = 0", arrayOf(path), null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val name = cursor.getString(1)
                    if (name.endsWith(".sltheme", ignoreCase = true)) {
                        files.add(mapOf("uri" to ContentUris.withAppendedId(downloads, cursor.getLong(0)).toString(),
                            "name" to name))
                    }
                }
            }
        }
        return files.sortedBy { it.getValue("name") }
    }

    fun read(context: Context, value: String): ByteArray {
        require(list(context).any { it["uri"] == value })
        val stream = context.contentResolver.openInputStream(Uri.parse(value))
            ?: error("无法打开主题文件")
        return stream.use { input ->
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(bytes.size() + count <= maxBytes) { "主题文件超过 48 MB" }
                bytes.write(buffer, 0, count)
            }
            bytes.toByteArray()
        }
    }

    fun save(context: Context, name: String, bytes: ByteArray): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        require(bytes.size <= maxBytes && name.endsWith(".sltheme") &&
            name.none { it == '/' || it == '\\' || it.isISOControl() })
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, path)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("无法创建主题文件")
        try {
            val stream = resolver.openOutputStream(uri) ?: error("无法写入主题文件")
            stream.use { it.write(bytes) }
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            check(resolver.update(uri, published, null, null) == 1)
            return true
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }
}
