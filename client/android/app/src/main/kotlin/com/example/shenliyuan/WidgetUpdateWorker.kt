package com.example.shenliyuan

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * WidgetUpdateWorker — 后台定时刷新桌面小组件
 *
 * 刷新逻辑：
 * 1. 读取 SharedPreferences 最新数据
 * 2. 对每个 widget 实例重建 RemoteViews（更新标题/日期）
 * 3. 调用 notifyAppWidgetViewDataChanged 触发 ListView 重新加载
 */
class WidgetUpdateWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        private const val TAG = "WidgetUpdateWorker"
        private const val WORK_NAME = "today_course_widget_update"

        fun enqueue(context: Context) {
            val request = PeriodicWorkRequestBuilder<WidgetUpdateWorker>(
                15, TimeUnit.MINUTES,
            )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request,
            )
            Log.d(TAG, "小组件定期刷新已入队")
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }

    override suspend fun doWork(): Result {
        return try {
            val refreshed = HomeWidgetRegistry.refreshAll(applicationContext)
            if (refreshed == 0) {
                Log.d(TAG, "无小组件实例，跳过刷新")
            } else {
                Log.d(TAG, "四类小组件刷新完成（$refreshed 个实例）")
            }
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "小组件刷新失败", e)
            Result.failure()
        }
    }
}
