package com.example.shenliyuan

import org.junit.Assert.assertEquals
import org.junit.Test

class DiagnosticLogPolicyTest {
    @Test
    fun `非连续重复事件仍在窗口内聚合`() {
        val entries = listOf(
            DiagnosticLogPolicy.Entry(
                id = "target",
                level = "warning",
                signature = "network|GET|timeout",
                timestamp = 1_000L,
                lastSeenAt = 1_000L,
            ),
            DiagnosticLogPolicy.Entry(
                id = "other",
                level = "info",
                signature = "app|resume|success",
                timestamp = 1_100L,
                lastSeenAt = 1_100L,
            ),
        )

        val index = DiagnosticLogPolicy.findMergeIndex(
            entries = entries,
            signature = "network|GET|timeout",
            now = 2_000L,
        )

        assertEquals(0, index)
    }

    @Test
    fun `超出容量时优先淘汰最旧普通信息并保留错误`() {
        val entries = mutableListOf(
            DiagnosticLogPolicy.Entry("error", "error", "e", 100L, 100L),
            DiagnosticLogPolicy.Entry("info-old", "info", "i1", 200L, 200L),
            DiagnosticLogPolicy.Entry("warning", "warning", "w", 300L, 300L),
            DiagnosticLogPolicy.Entry("info-new", "info", "i2", 400L, 400L),
        )

        DiagnosticLogPolicy.enforceEntryLimit(entries, maxEntries = 3)

        assertEquals(listOf("error", "warning", "info-new"), entries.map { it.id })
    }

    @Test
    fun `不同等级按各自保留期清理`() {
        val day = 24L * 60 * 60 * 1000
        val now = 20 * day
        val entries = mutableListOf(
            DiagnosticLogPolicy.Entry("error-old", "error", "e1", now - 15 * day, now - 15 * day),
            DiagnosticLogPolicy.Entry("error-kept", "error", "e2", now - 10 * day, now - 10 * day),
            DiagnosticLogPolicy.Entry("warning-old", "warning", "w1", now - 8 * day, now - 8 * day),
            DiagnosticLogPolicy.Entry("warning-kept", "warning", "w2", now - 5 * day, now - 5 * day),
            DiagnosticLogPolicy.Entry("info-old", "info", "i1", now - 4 * day, now - 4 * day),
            DiagnosticLogPolicy.Entry("info-kept", "info", "i2", now - 2 * day, now - 2 * day),
        )

        DiagnosticLogPolicy.removeExpired(entries, now)

        assertEquals(
            listOf("error-kept", "warning-kept", "info-kept"),
            entries.map { it.id },
        )
    }
}
