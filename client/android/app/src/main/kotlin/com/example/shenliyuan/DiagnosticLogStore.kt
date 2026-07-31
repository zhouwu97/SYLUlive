package com.example.shenliyuan

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.AtomicFile
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

object DiagnosticLogStore {
    private const val TAG = "DiagnosticLogStore"
    private const val MAX_ENTRIES = 500
    private const val MAX_FILE_SIZE = 4 * 1024 * 1024L

    private val executor = Executors.newSingleThreadExecutor()
    private val sessionId = UUID.randomUUID().toString().substring(0, 8)
    private val processStartedAt = System.currentTimeMillis()
    private val processPid = android.os.Process.myPid()

    data class EventContext(
        val eventCode: String = "",
        val category: String = "app",
        val operation: String = "",
        val result: String = "",
        val traceId: String = "",
        val durationMs: Long? = null,
        val httpStatus: Int? = null,
        val retryCount: Int = 0,
        val route: String = "",
        val taskId: Int? = null,
        val isForeground: Boolean? = null,
        val metadata: Map<String, Any?> = emptyMap(),
    )

    fun info(
        context: Context,
        source: String,
        type: String,
        summary: String,
        detail: String = "",
        event: EventContext = EventContext(),
    ) {
        record(context, "info", source, type, summary, detail, event)
    }

    fun warning(
        context: Context,
        source: String,
        type: String,
        summary: String,
        detail: String = "",
        event: EventContext = EventContext(),
    ) {
        record(context, "warning", source, type, summary, detail, event)
    }

    fun error(
        context: Context,
        source: String,
        type: String,
        summary: String,
        detail: String = "",
        event: EventContext = EventContext(),
    ) {
        record(context, "error", source, type, summary, detail, event)
    }

    fun critical(
        context: Context,
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String = "",
        event: EventContext = EventContext(),
    ) {
        val task = executor.submit {
            recordInternal(context, level, source, type, summary, detail, event)
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
        detail: String,
        event: EventContext,
    ) {
        executor.execute {
            recordInternal(context, level, source, type, summary, detail, event)
        }
    }

    private fun recordInternal(
        context: Context,
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String,
        event: EventContext,
    ) {
        val appContext = context.applicationContext
        val timestamp = System.currentTimeMillis()
        val elapsedRealtime = SystemClock.elapsedRealtime()

        val safeSource = sanitize(source).take(32)
        val safeType = sanitize(type).take(80)
        val safeSummary = sanitize(summary).take(500)
        val safeDetail = truncateDetail(sanitize(detail))
        val safeEventCode = sanitize(event.eventCode).take(80)
        val safeCategory = sanitize(event.category).take(32).ifBlank { "app" }
        val safeOperation = sanitize(event.operation).take(64)
        val safeResult = sanitize(event.result).take(24)
        val safeTraceId = sanitize(event.traceId).take(80)
        val safeRoute = sanitize(event.route).take(160)
        val safeMetadata = sanitizeMetadata(event.metadata)

        try {
            val file = File(appContext.filesDir, "diagnostic_logs.jsonl")
            val atomicFile = AtomicFile(file)
            val entries = applyRetentionPolicy(
                readEntriesAtomically(atomicFile),
                timestamp,
                MAX_ENTRIES,
            )

            val signature = signatureFor(
                level = level,
                source = safeSource,
                type = safeType,
                summary = safeSummary,
                detail = safeDetail,
                eventCode = safeEventCode,
                category = safeCategory,
                operation = safeOperation,
                result = safeResult,
                httpStatus = event.httpStatus,
                route = safeRoute,
            )
            val mergeIndex = DiagnosticLogPolicy.findMergeIndex(
                policyEntries(entries),
                signature,
                timestamp,
            )

            if (mergeIndex != null) {
                val matchedEntry = entries.removeAt(mergeIndex)
                matchedEntry.put(
                    "repeatCount",
                    matchedEntry.optInt("repeatCount", 1) + 1,
                )
                matchedEntry.put("lastSeenAt", timestamp)
                matchedEntry.put("timestamp", timestamp)
                event.durationMs?.let { matchedEntry.put("durationMs", it.coerceAtLeast(0)) }
                matchedEntry.put("retryCount", event.retryCount.coerceAtLeast(0))
                if (safeMetadata.length() > 0) {
                    matchedEntry.put("metadata", safeMetadata)
                }
                entries.add(matchedEntry)
            } else {
                entries.add(
                    JSONObject().apply {
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
                        put("appVersion", BuildConfig.VERSION_NAME)
                        put("manufacturer", Build.MANUFACTURER)
                        put("model", Build.MODEL)
                        put("sdkInt", Build.VERSION.SDK_INT)
                        put("repeatCount", 1)
                        put("firstSeenAt", timestamp)
                        put("lastSeenAt", timestamp)
                        put("eventCode", safeEventCode)
                        put("category", safeCategory)
                        put("operation", safeOperation)
                        put("result", safeResult)
                        put("traceId", safeTraceId)
                        event.durationMs?.let { put("durationMs", it.coerceAtLeast(0)) }
                        event.httpStatus?.let { put("httpStatus", it) }
                        put("retryCount", event.retryCount.coerceAtLeast(0))
                        put("route", safeRoute)
                        event.taskId?.let { put("taskId", it) }
                        event.isForeground?.let { put("isForeground", it) }
                        if (safeMetadata.length() > 0) put("metadata", safeMetadata)
                    },
                )
            }

            val limitedEntries = applyRetentionPolicy(entries, timestamp, MAX_ENTRIES)
            writeEntriesAtomically(atomicFile, limitedEntries)
            trimToFileSize(atomicFile, file, limitedEntries, timestamp)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update diagnostic logs", e)
        }
    }

    private fun signatureFor(
        level: String,
        source: String,
        type: String,
        summary: String,
        detail: String,
        eventCode: String,
        category: String,
        operation: String,
        result: String,
        httpStatus: Int?,
        route: String,
    ): String =
        if (eventCode.isNotBlank()) {
            listOf(
                level,
                eventCode,
                category,
                operation,
                result,
                httpStatus?.toString().orEmpty(),
                route,
                summary,
            ).joinToString("|")
        } else {
            "$level|$source|$type|$summary|$detail"
        }

    private fun signatureFor(entry: JSONObject): String =
        signatureFor(
            level = entry.optString("level"),
            source = entry.optString("source"),
            type = entry.optString("type"),
            summary = entry.optString("summary"),
            detail = entry.optString("detail"),
            eventCode = entry.optString("eventCode"),
            category = entry.optString("category", "app"),
            operation = entry.optString("operation"),
            result = entry.optString("result"),
            httpStatus = if (entry.has("httpStatus")) entry.optInt("httpStatus") else null,
            route = entry.optString("route"),
        )

    private fun policyEntries(entries: List<JSONObject>): List<DiagnosticLogPolicy.Entry> =
        entries.mapIndexed { index, entry ->
            DiagnosticLogPolicy.Entry(
                id = index.toString(),
                level = entry.optString("level", "info"),
                signature = signatureFor(entry),
                timestamp = entry.optLong("timestamp", 0),
                lastSeenAt = entry.optLong(
                    "lastSeenAt",
                    entry.optLong("timestamp", 0),
                ),
            )
        }

    private fun applyRetentionPolicy(
        entries: List<JSONObject>,
        now: Long,
        maxEntries: Int,
    ): MutableList<JSONObject> {
        val policyEntries = policyEntries(entries).toMutableList()
        DiagnosticLogPolicy.removeExpired(policyEntries, now)
        DiagnosticLogPolicy.enforceEntryLimit(policyEntries, maxEntries)
        val retainedIndices = policyEntries.mapTo(hashSetOf()) { it.id.toInt() }
        return entries.filterIndexed { index, _ -> index in retainedIndices }.toMutableList()
    }

    private fun trimToFileSize(
        atomicFile: AtomicFile,
        file: File,
        entries: MutableList<JSONObject>,
        now: Long,
    ) {
        while (file.length() > MAX_FILE_SIZE && entries.size > 1) {
            val trimmed = applyRetentionPolicy(entries, now, entries.size - 1)
            entries.clear()
            entries.addAll(trimmed)
            writeEntriesAtomically(atomicFile, entries)
        }
    }

    private fun sanitizeMetadata(metadata: Map<String, Any?>): JSONObject {
        val result = JSONObject()
        metadata.entries.take(32).forEach { (key, value) ->
            val safeKey = sanitize(key).take(48)
            if (safeKey.isNotBlank()) {
                result.put(safeKey, sanitizeJsonValue(value, depth = 0))
            }
        }
        return result
    }

    private fun sanitizeJsonValue(value: Any?, depth: Int): Any {
        if (value == null) return JSONObject.NULL
        if (depth >= 3) return sanitize(value.toString()).take(500)
        return when (value) {
            is String -> sanitize(value).take(1000)
            is Number, is Boolean -> value
            is Map<*, *> -> {
                val result = JSONObject()
                value.entries.take(24).forEach { (key, item) ->
                    result.put(
                        sanitize(key?.toString().orEmpty()).take(48),
                        sanitizeJsonValue(item, depth + 1),
                    )
                }
                result
            }
            is Iterable<*> -> {
                val result = JSONArray()
                value.take(24).forEach { result.put(sanitizeJsonValue(it, depth + 1)) }
                result
            }
            else -> sanitize(value.toString()).take(1000)
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
                        map[key] = jsonToPlatformValue(json.get(key))
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
                recordInternal(
                    appContext,
                    "info",
                    "系统",
                    "清理记录",
                    "日志已清空",
                    "",
                    EventContext(
                        eventCode = "diagnostic_logs_cleared",
                        category = "app",
                        operation = "clear",
                        result = "success",
                    ),
                )
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
        detail: String,
        event: EventContext = EventContext(),
    ) {
        record(context, level, source, type, summary, detail, event)
    }

    private fun jsonToPlatformValue(value: Any?): Any? =
        when (value) {
            JSONObject.NULL -> null
            is JSONObject -> {
                val result = mutableMapOf<String, Any?>()
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    result[key] = jsonToPlatformValue(value.get(key))
                }
                result
            }
            is JSONArray -> List(value.length()) { index ->
                jsonToPlatformValue(value.get(index))
            }
            else -> value
        }
}
