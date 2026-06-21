package com.example.shenliyuan

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
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
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<WidgetUpdateWorker>(
                15, TimeUnit.MINUTES,
            )
                .setConstraints(constraints)
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
            val appWidgetManager = AppWidgetManager.getInstance(applicationContext)
            val component = ComponentName(applicationContext, TodayCourseWidgetProvider::class.java)
            val ids = appWidgetManager.getAppWidgetIds(component)

            if (ids.isEmpty()) {
                Log.d(TAG, "无小组件实例，跳过刷新")
                return Result.success()
            }

            // 重建每个 widget 实例的 RemoteViews（更新标题/日期）
            for (id in ids) {
                val views = TodayCourseWidgetProvider.buildRemoteViews(applicationContext, id)
                appWidgetManager.updateAppWidget(id, views)
            }

            // 通知 ListView 数据已变化 → 触发 onDataSetChanged() 重新读 SP
            appWidgetManager.notifyAppWidgetViewDataChanged(ids, R.id.course_list_view)

            Log.d(TAG, "小组件刷新完成 (${ids.size} 个实例)")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "小组件刷新失败", e)
            Result.failure()
        }
    }
}
