package com.example.shenliyuan

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

/**
 * 兼容旧 WorkManager 类型名，但任务本身已停用。
 *
 * 启动迁移会取消旧任务；即使系统在取消前恢复了旧任务，也只返回成功，
 * 不读取凭据、不访问网络、不发送通知。
 */
class GradeReminderWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result = Result.success()
}
