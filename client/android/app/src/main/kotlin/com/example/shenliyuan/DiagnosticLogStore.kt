package com.example.shenliyuan

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.AtomicFile
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

object DiagnosticLogStore {
    private const val TAG = "DiagnosticLogStore"
    private const val MAX_ENTRIES = 200
    private const val MAX_FILE_SIZE = 2 * 1024 * 1024L // 2MB
    private const val RETENTION_MS = 7L * 24 * 60 * 60 * 1000L // 7 days
    private const val REPEAT_WINDOW_MS = 10 * 60 * 1000L // 10 minutes

    private val executor = Executors.newSingleThreadExecutor()
    private val sessionId = UUID.randomUUID().toString().substring(0, 8)
    private val processStartedAt = System.currentTimeMillis()
    private val processPid = android.os.Process.myPid()

    fun info(context: Context, source: String, type: String, summary: String, detail: String = "") {
        record(context, "info", source, type, summary, detail)
    }

    fun warning(context: Context, source: String, type: String, summary: String, detail: String = "") {
        record(context, "warning", source, type, summary, detail)
    }

    fun error(context: Context, source: String, type: String, summary: String, detail: String = "") {
        record(context, "error", source, type, summary, detail)
    }

    fun critical(
        context: Context,
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String = ""
    ) {
        val task = executor.submit {
            recordInternal(context, level, source, type, summary, detail)
        }
        runCatching {
            task.get(500, TimeUnit.MILLISECONDS)
        }
    }

    private fun sanitize(value: String): String {
        return value
            .replace(Regex("""(?i)Bearer\s+[A-Za-z0-9\-._~+/]+=*"""), "Bearer ***")
            .replace(Regex("""(?i)("?(?:token|password|cookie|authorization)"?\s*[:=]\s*"?)[^"\s,}]+"""), "$1***")
            // registration id
            .replace(Regex("""registrationId=([a-zA-Z0-9]+)""")) { matchResult ->
                val rid = matchResult.groupValues[1]
                val safeRid = if (rid.length > 6) "***${rid.takeLast(6)}" else "***"
                "registrationId=$safeRid"
            }
    }

    private fun truncateDetail(detail: String): String {
        return if (detail.length > 8000) {
            detail.substring(0, 8000) + "\n...[truncated]"
        } else {
            detail
        }
    }

    private fun record(
        context: Context,
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String
    ) {
        executor.execute {
            recordInternal(context, level, source, type, summary, detail)
        }
    }

    private fun recordInternal(
        context: Context,
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String
    ) {
        val appContext = context.applicationContext
        val timestamp = System.currentTimeMillis()
        val elapsedRealtime = SystemClock.elapsedRealtime()

        val safeSource = sanitize(source).take(32)
        val safeType = sanitize(type).take(80)
        val safeSummary = sanitize(summary).take(500)
        val safeDetail = truncateDetail(sanitize(detail))

        try {
                val file = File(appContext.filesDir, "diagnostic_logs.jsonl")
                val atomicFile = AtomicFile(file)

                val entries = readEntriesAtomically(atomicFile)

                // Filter out old logs
                val cutoff = timestamp - RETENTION_MS
                entries.removeAll { it.optLong("timestamp", 0) < cutoff }

                // Check for deduplication
                val signature = "$level|$safeSource|$safeType|$safeSummary|$safeDetail"
                var merged = false

                if (entries.isNotEmpty()) {
                    val lastEntry = entries.last()
                    val lastLevel = lastEntry.optString("level")
                    val lastSource = lastEntry.optString("source")
                    val lastType = lastEntry.optString("type")
                    val lastSummary = lastEntry.optString("summary")
                    val lastDetail = lastEntry.optString("detail")
                    val lastSignature = "$lastLevel|$lastSource|$lastType|$lastSummary|$lastDetail"

                    if (signature == lastSignature) {
                        val lastSeenAt = lastEntry.optLong("lastSeenAt", lastEntry.optLong("timestamp"))
                        if (timestamp - lastSeenAt < REPEAT_WINDOW_MS) {
                            val repeatCount = lastEntry.optInt("repeatCount", 1) + 1
                            lastEntry.put("repeatCount", repeatCount)
                            lastEntry.put("lastSeenAt", timestamp)
                            merged = true
                        }
                    }
                }

                if (!merged) {
                    val entry = JSONObject().apply {
                        put("id", UUID.randomUUID().toString())
                        put("timestamp", timestamp)
                        put("elapsedRealtime", elapsedRealtime)
                        put("level", level)
                        put("source", safeSource)
                        put("type", safeType)
                        put("summary", safeSummary)
                        put("detail", safeDetail)
                        put("sessionId", sessionId)
                        put("pid", processPid)
                        put("appVersion", "1.5.16")
                        put("manufacturer", Build.MANUFACTURER)
                        put("model", Build.MODEL)
                        put("sdkInt", Build.VERSION.SDK_INT)
                        put("repeatCount", 1)
                        put("firstSeenAt", timestamp)
                        put("lastSeenAt", timestamp)
                    }
                    entries.add(entry)
                }

                // Enforce max entries
                while (entries.size > MAX_ENTRIES) {
                    entries.removeAt(0)
                }

                // Write atomically
                writeEntriesAtomically(atomicFile, entries)

                // Check size
                if (file.length() > MAX_FILE_SIZE) {
                    // Truncate to half
                    while (entries.size > MAX_ENTRIES / 2) {
                        entries.removeAt(0)
                    }
                    writeEntriesAtomically(atomicFile, entries)
                }

            } catch (e: Exception) {
                Log.e(TAG, "Failed to update diagnostic logs", e)
            }
        }

    private fun readEntriesAtomically(atomicFile: AtomicFile): MutableList<JSONObject> {
        return try {
            atomicFile.openRead()
                .bufferedReader(Charsets.UTF_8)
                .useLines { lines ->
                    lines.mapNotNull { line ->
                        runCatching { JSONObject(line) }.getOrNull()
                    }.toMutableList()
                }
        } catch (_: FileNotFoundException) {
            mutableListOf()
        }
    }

    private fun writeEntriesAtomically(atomicFile: AtomicFile, entries: List<JSONObject>) {
        val stream = atomicFile.startWrite()
        try {
            val writer = stream.bufferedWriter(Charsets.UTF_8)
            for (entry in entries) {
                writer.write(entry.toString())
                writer.newLine()
            }
            writer.flush()
            atomicFile.finishWrite(stream)
        } catch (e: Exception) {
            atomicFile.failWrite(stream)
            throw e
        }
    }

    fun getLogs(context: Context, onSuccess: (List<Map<String, Any?>>) -> Unit, onError: (Exception) -> Unit) {
        val appContext = context.applicationContext
        executor.execute {
            try {
                val file = File(appContext.filesDir, "diagnostic_logs.jsonl")
                val atomicFile = AtomicFile(file)
                val entries = readEntriesAtomically(atomicFile)
                val list = mutableListOf<Map<String, Any?>>()
                for (json in entries) {
                    val map = mutableMapOf<String, Any?>()
                    val keys = json.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        map[key] = json.get(key)
                    }
                    list.add(map)
                }
                list.reverse()
                onSuccess(list)
            } catch (e: Exception) {
                onError(e)
            }
        }
    }

    fun clearLogs(context: Context, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        val appContext = context.applicationContext
        executor.execute {
            try {
                val file = File(appContext.filesDir, "diagnostic_logs.jsonl")
                val atomicFile = AtomicFile(file)
                val stream = atomicFile.startWrite()
                try {
                    atomicFile.finishWrite(stream)
                } catch (e: Exception) {
                    atomicFile.failWrite(stream)
                    throw e
                }
                onSuccess()
                recordInternal(appContext, "info", "系统", "清理记录", "日志已清空", "")
            } catch (e: Exception) {
                onError(e)
            }
        }
    }

    fun writeFromFlutter(
        context: Context,
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String
    ) {
        record(context, level, source, type, summary, detail)
    }
}
