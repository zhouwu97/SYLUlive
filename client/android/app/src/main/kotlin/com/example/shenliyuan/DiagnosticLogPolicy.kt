package com.example.shenliyuan

object DiagnosticLogPolicy {
    private const val REPEAT_WINDOW_MS = 10L * 60 * 1000
    private const val DAY_MS = 24L * 60 * 60 * 1000

    data class Entry(
        val id: String,
        val level: String,
        val signature: String,
        val timestamp: Long,
        val lastSeenAt: Long,
    )

    fun findMergeIndex(
        entries: List<Entry>,
        signature: String,
        now: Long,
    ): Int? {
        for (index in entries.indices.reversed()) {
            val entry = entries[index]
            if (entry.signature == signature &&
                now - entry.lastSeenAt < REPEAT_WINDOW_MS
            ) {
                return index
            }
        }
        return null
    }

    fun enforceEntryLimit(entries: MutableList<Entry>, maxEntries: Int) {
        while (entries.size > maxEntries) {
            val index = entries.indices.minWithOrNull(
                compareBy<Int>(
                    { evictionPriority(entries[it].level) },
                    { entries[it].timestamp },
                ),
            ) ?: return
            entries.removeAt(index)
        }
    }

    fun removeExpired(entries: MutableList<Entry>, now: Long) {
        entries.removeAll { entry ->
            val retention = when (entry.level) {
                "error" -> 14 * DAY_MS
                "warning" -> 7 * DAY_MS
                else -> 3 * DAY_MS
            }
            entry.timestamp < now - retention
        }
    }

    private fun evictionPriority(level: String): Int =
        when (level) {
            "info" -> 0
            "warning" -> 1
            else -> 2
        }
}
