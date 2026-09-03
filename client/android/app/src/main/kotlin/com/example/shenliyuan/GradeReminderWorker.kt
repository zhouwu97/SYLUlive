package com.example.shenliyuan

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

class GradeReminderWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val context = applicationContext
        val p = GradeReminderScheduler.prefs(context)
        val userId = GradeReminderScheduler.runtimeUserId(context)
        if (userId.isNullOrBlank()) return Result.success()
        if (!p.getBoolean(GradeReminderScheduler.enabledKey(userId), false)) {
            return Result.success()
        }

        val token = p.getString(GradeReminderScheduler.authTokenKey(), null)
        if (token.isNullOrBlank()) {
            markNeedAction(userId, "login", "缺少登录 token")
            return Result.success()
        }

        val apiBaseUrl = GradeReminderScheduler.apiBaseUrl(context)
        val year = p.getString(GradeReminderScheduler.yearKey(userId), null)
        val semester = if (p.contains(GradeReminderScheduler.semesterKey(userId))) {
            p.getInt(GradeReminderScheduler.semesterKey(userId), 0)
        } else {
            0
        }
        if (apiBaseUrl.isNullOrBlank() || year.isNullOrBlank() || semester == 0) {
            DiagnosticLogStore.warning(
                context,
                source = "成绩提醒",
                type = "配置缺失",
                summary = "成绩提醒缺少运行配置，跳过本轮检查",
                detail = "userId=$userId apiBaseUrl=${apiBaseUrl ?: ""} year=${year ?: ""} semester=$semester",
            )
            return Result.success()
        }

        p.edit()
            .putString(GradeReminderScheduler.stateKey(userId), "checking")
            .putLong(GradeReminderScheduler.lastCheckKey(userId), System.currentTimeMillis())
            .apply()

        val response = try {
            fetchGrades(apiBaseUrl, token, year, semester)
        } catch (e: Exception) {
            recordFailure(userId, "网络异常", e.message.orEmpty())
            return Result.retry()
        }

        if (response.statusCode == 401) {
            markNeedAction(userId, "login", "登录状态已失效")
            return Result.success()
        }
        if (response.statusCode == 400 && response.body.contains("绑定")) {
            markNeedAction(userId, "bind", "教务账号未绑定或绑定失效")
            return Result.success()
        }
        if (response.statusCode == 409 && response.body.contains("EDU_SESSION_EXPIRED")) {
            markNeedAction(userId, "bind", "教务登录状态已失效")
            return Result.success()
        }
        if (response.statusCode >= 500) {
            recordFailure(userId, "服务端异常", "status=${response.statusCode}")
            return Result.retry()
        }
        if (response.statusCode !in 200..299) {
            markNeedAction(userId, "edu", "教务服务暂不可用 status=${response.statusCode}")
            return Result.success()
        }

        val json = runCatching { JSONObject(response.body) }.getOrNull()
        if (json == null) {
            recordFailure(userId, "响应异常", "成绩接口返回非 JSON")
            return Result.retry()
        }

        val grades = json.optJSONArray("grades") ?: JSONArray()
        val newSnapshot = GradeReminderSnapshot.fromGrades(grades)
        val snapshotKey = GradeReminderScheduler.snapshotKey(userId, year, semester)
        val oldSnapshot = GradeReminderSnapshot.fromJson(p.getString(snapshotKey, null))

        if (grades.length() == 0 && oldSnapshot != null && oldSnapshot.grades.isNotEmpty()) {
            DiagnosticLogStore.warning(
                context,
                source = "成绩提醒",
                type = "空数组保护",
                summary = "接口返回空成绩，保留旧基线",
                detail = "userId=$userId year=$year semester=$semester",
            )
            markSuccess(userId)
            return Result.success()
        }

        val isBaselineProtection = oldSnapshot != null && oldSnapshot.initialized &&
            oldSnapshot.effectiveCount() <= 2 && newSnapshot.effectiveCount() >= 10

        if (oldSnapshot == null || oldSnapshot.isPendingOnly() || !oldSnapshot.initialized || isBaselineProtection) {
            p.edit()
                .putString(snapshotKey, newSnapshot.toJson().toString())
                .putString(GradeReminderScheduler.stateKey(userId), "ready")
                .apply()
            markSuccess(userId)
            val isFix = oldSnapshot != null && oldSnapshot.initialized && oldSnapshot.isPendingOnly()
            if (isFix || isBaselineProtection) {
                GradeReminderScheduler.clearAllGradeUpdateNotifications(context)
            }
            DiagnosticLogStore.info(
                context,
                source = "成绩提醒",
                type = if (isBaselineProtection) "基线保护" else if (isFix) "基线修复" else "基线",
                summary = if (isBaselineProtection) "检测到疑似历史成绩批量变化，已重建基线并跳过历史批量提醒" 
                          else if (isFix) "旧成绩提醒基线为空或仅包含占位成绩，已用本次结果重建基线并跳过历史批量提醒" 
                          else "已保存成绩提醒首次基线",
                detail = "userId=$userId year=$year semester=$semester count=${grades.length()}",
            )
            return Result.success()
        }

        val diff = newSnapshot.diffFrom(oldSnapshot)
        if (diff.hasChanges) {
            val changeHash = diff.changeHash()
            if (!alreadyNotified(userId, year, semester, changeHash)) {
                showGradeNotification(userId, year, semester, diff)
                rememberHash(userId, year, semester, changeHash)
            }
        }

        p.edit()
            .putString(snapshotKey, newSnapshot.toJson().toString())
            .putString(GradeReminderScheduler.stateKey(userId), "ready")
            .apply()
        markSuccess(userId)
        return Result.success()
    }

    private fun fetchGrades(
        apiBaseUrl: String,
        token: String,
        year: String,
        semester: Int,
    ): GradeReminderHttpResponse {
        val url = URL(apiBaseUrl.trimEnd('/') + "/edu/grades")
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 30_000
            readTimeout = 60_000
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            setRequestProperty("Authorization", "Bearer $token")
        }
        val body = JSONObject()
            .put("year", year)
            .put("semester", semester)
            .toString()
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        val code = connection.responseCode
        val stream = if (code in 200..399) connection.inputStream else connection.errorStream
        val text = stream?.use {
            BufferedReader(InputStreamReader(it, Charsets.UTF_8)).readText()
        }.orEmpty()
        connection.disconnect()
        return GradeReminderHttpResponse(code, text)
    }

    private fun markSuccess(userId: String) {
        GradeReminderScheduler.prefs(applicationContext).edit()
            .putLong(
                GradeReminderScheduler.lastSuccessKey(userId),
                System.currentTimeMillis(),
            )
            .putInt(GradeReminderScheduler.failuresKey(userId), 0)
            .remove(GradeReminderScheduler.needActionKey(userId))
            .apply()
    }

    private fun recordFailure(userId: String, summary: String, detail: String) {
        val p = GradeReminderScheduler.prefs(applicationContext)
        val failures = p.getInt(GradeReminderScheduler.failuresKey(userId), 0) + 1
        p.edit()
            .putInt(GradeReminderScheduler.failuresKey(userId), failures)
            .putString(GradeReminderScheduler.stateKey(userId), "temp_failed")
            .apply()
        DiagnosticLogStore.warning(
            applicationContext,
            source = "成绩提醒",
            type = "检查失败",
            summary = summary,
            detail = detail,
        )
    }

    private fun markNeedAction(userId: String, action: String, summary: String) {
        GradeReminderScheduler.prefs(applicationContext).edit()
            .putString(GradeReminderScheduler.needActionKey(userId), action)
            .putString(
                GradeReminderScheduler.stateKey(userId),
                when (action) {
                    "login" -> "need_login"
                    "bind" -> "need_bind"
                    else -> "temp_failed"
                },
            )
            .apply()
        showActionNotificationOnce(userId, action, summary)
        DiagnosticLogStore.warning(
            applicationContext,
            source = "成绩提醒",
            type = "需要处理",
            summary = summary,
            detail = "userId=$userId action=$action",
        )
    }

    private fun showActionNotificationOnce(userId: String, action: String, summary: String) {
        val key = when (action) {
            "login" -> GradeReminderScheduler.needLoginNotifiedKey(userId)
            "bind" -> GradeReminderScheduler.needBindNotifiedKey(userId)
            else -> return
        }
        val p = GradeReminderScheduler.prefs(applicationContext)
        if (p.getBoolean(key, false)) return
        p.edit().putBoolean(key, true).apply()
        if (!canPostNotifications()) return

        ensureChannel()
        val year = p.getString(GradeReminderScheduler.yearKey(userId), null)
        val semester = if (p.contains(GradeReminderScheduler.semesterKey(userId))) {
            p.getInt(GradeReminderScheduler.semesterKey(userId), 0)
        } else {
            0
        }
        val uri = if (!year.isNullOrBlank() && semester != 0) {
            "sylulive://grades?year=$year&semester=$semester"
        } else {
            "sylulive://grades"
        }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
            .setPackage(applicationContext.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            ("grade_action_$userId$action").hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = when (action) {
            "login" -> "成绩提醒需要重新登录"
            "bind" -> "成绩提醒需要重新绑定教务"
            else -> "成绩提醒需要处理"
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(applicationContext, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(applicationContext)
        }
        builder
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(summary)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_STATUS)
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
            ?: return
        manager.notify(("grade_action_$userId$action").hashCode() and 0x7fffffff, builder.build())
    }

    private fun alreadyNotified(
        userId: String,
        year: String,
        semester: Int,
        hash: String,
    ): Boolean {
        if (hash.isBlank()) return true
        val raw = GradeReminderScheduler.prefs(applicationContext)
            .getStringSet(GradeReminderScheduler.hashesKey(userId, year, semester), emptySet())
            ?: emptySet()
        return hash in raw
    }

    private fun rememberHash(
        userId: String,
        year: String,
        semester: Int,
        hash: String,
    ) {
        if (hash.isBlank()) return
        val key = GradeReminderScheduler.hashesKey(userId, year, semester)
        val old = GradeReminderScheduler.prefs(applicationContext)
            .getStringSet(key, emptySet())
            ?.toMutableList()
            ?: mutableListOf()
        old.remove(hash)
        old.add(hash)
        while (old.size > 20) old.removeAt(0)
        GradeReminderScheduler.prefs(applicationContext).edit()
            .putStringSet(key, old.toSet())
            .apply()
    }

    private fun showGradeNotification(
        userId: String,
        year: String,
        semester: Int,
        diff: GradeReminderDiff,
    ) {
        if (!canPostNotifications()) {
            DiagnosticLogStore.warning(
                applicationContext,
                source = "成绩提醒",
                type = "通知权限",
                summary = "发现成绩更新，但通知权限未开启",
            )
            return
        }

        ensureChannel()
        val changes = diff.changes
        val preview = changes.take(2).joinToString("，") {
            "${it.next.name} ${it.next.displayGrade()}"
        }
        val body = if (changes.size > 2) {
            "$preview 等 ${changes.size} 门成绩已更新"
        } else {
            preview
        }
        val detail = changes.joinToString("\n") { it.summary() }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("sylulive://grades?year=$year&semester=$semester"))
            .setPackage(applicationContext.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            (userId + year + semester + diff.changeHash()).hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(applicationContext, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(applicationContext)
        }
        builder
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setContentTitle("成绩有更新")
            .setContentText(body.ifBlank { "有新成绩或成绩变化" })
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            builder.setStyle(
                Notification.BigTextStyle(builder)
                    .bigText(detail)
                    .setBigContentTitle("成绩有更新")
                    .setSummaryText("点击查看 $year 学期成绩"),
            )
        }

        val manager = applicationContext.getSystemService(NotificationManager::class.java)
            ?: return
            
        GradeReminderScheduler.clearAllGradeUpdateNotifications(applicationContext)
        
        val notificationId = (userId + year + semester).hashCode() and 0x7fffffff
        runCatching {
            manager.notify(notificationId, builder.build())
        }.onFailure {
            DiagnosticLogStore.warning(
                applicationContext,
                source = "成绩提醒",
                type = "通知失败",
                summary = "成绩更新通知发送失败",
                detail = it.message.orEmpty(),
            )
        }
    }

    private fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return applicationContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
            ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "成绩更新提醒",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "有新成绩或成绩变化时提醒"
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }



    companion object {
        const val CHANNEL_ID = "grade_updates"
    }
}

data class GradeReminderHttpResponse(
    val statusCode: Int,
    val body: String,
)
