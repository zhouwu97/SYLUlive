package com.example.shenliyuan

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import cn.jpush.android.api.JPushMessage
import cn.jpush.android.api.NotificationMessage
import com.jiguang.jpush.JPushEventReceiver
import org.json.JSONObject

class PrivateMessageJPushReceiver : JPushEventReceiver() {

    companion object {
        private const val RECONCILE_DEBOUNCE_MS = 800L

        private var lastReconcileRequested = 0L

        /** 去重协调：同 800ms 内多次触发只执行一次 */
        fun requestReconcile(context: Context) {
            val now = System.currentTimeMillis()
            if (now - lastReconcileRequested < RECONCILE_DEBOUNCE_MS) return
            lastReconcileRequested = now

            retryHandler.postDelayed({
                KeepAliveForegroundService.reconcileAliasState(context)
            }, RECONCILE_DEBOUNCE_MS)
        }
        // Sequence 编码：高位区分操作类型，低位携带 generation
        // 1_xxx_xxx = Alias 绑定/恢复
        // 2_xxx_xxx = Alias 删除
        private const val SEQ_BASE_RESTORE = 1_000_000
        private const val SEQ_BASE_DELETE  = 2_000_000

        /** 由 generation 生成唯一删除 sequence */
        fun deleteSequence(generation: Int): Int = SEQ_BASE_DELETE + generation

        /** 由 generation 生成唯一恢复 sequence */
        fun restoreSequence(generation: Int): Int = SEQ_BASE_RESTORE + generation

        /** 从 sequence 反解 generation */
        fun generationFromSequence(sequence: Int): Int = sequence % 1_000_000

        /** 判断是否为删除操作的 sequence */
        fun isDeleteSequence(sequence: Int): Boolean = sequence in SEQ_BASE_DELETE until SEQ_BASE_DELETE + 1_000_000

        /** 判断是否为恢复操作的 sequence */
        fun isRestoreSequence(sequence: Int): Boolean = sequence in SEQ_BASE_RESTORE until SEQ_BASE_RESTORE + 1_000_000

        // 重试配置
        private const val MAX_RETRIES = 3
        private val RETRY_DELAYS = longArrayOf(2_000L, 5_000L, 15_000L)

        /** 已安排的删除重试（key: generation, value: retryCount） */
        private val deleteRetries = mutableMapOf<Int, Int>()
        private val scheduledDeleteGenerations = mutableSetOf<Int>()

        /** 已安排的恢复重试（key: generation, value: retryCount） */
        private val restoreRetries = mutableMapOf<Int, Int>()
        private val scheduledRestoreGenerations = mutableSetOf<Int>()

        private val retryHandler = Handler(Looper.getMainLooper())

        /** 安排删除重试 */
        fun scheduleDeleteRetry(
            context: Context,
            generation: Int,
        ) {
            // 防止同一 generation 安排多个并发重试
            if (!scheduledDeleteGenerations.add(generation)) return

            val retryCount = deleteRetries.getOrDefault(generation, 0)
            if (retryCount >= MAX_RETRIES) {
                DiagnosticLogStore.warning(
                    context,
                    source = "推送",
                    type = "Alias 删除放弃",
                    summary = "Alias 删除重试 $MAX_RETRIES 次后仍失败，等待下次进程启动",
                    detail = "gen=$generation",
                )
                deleteRetries.remove(generation)
                scheduledDeleteGenerations.remove(generation)
                return
            }

            val delay = RETRY_DELAYS[retryCount]
            deleteRetries[generation] = retryCount + 1

            DiagnosticLogStore.info(
                context,
                source = "推送",
                type = "Alias 删除重试安排",
                summary = "将在 ${delay}ms 后第 ${retryCount + 1} 次重试删除",
                detail = "gen=$generation",
            )

            retryHandler.postDelayed({
                // 释放“已调度”标记，允许后续异步失败继续安排重试
                scheduledDeleteGenerations.remove(generation)

                val currentState = KeepAliveForegroundService.getAliasState(context)
                val currentGen = KeepAliveForegroundService.getAliasGeneration(context)

                if (currentState != "pending_delete" || currentGen != generation) {
                    DiagnosticLogStore.info(
                        context,
                        source = "推送",
                        type = "Alias 删除取消",
                        summary = "状态或 generation 已变化，取消删除重试",
                        detail = "state=$currentState gen=$currentGen expectedGen=$generation",
                    )
                    deleteRetries.remove(generation)
                    return@postDelayed
                }

                val sequence = deleteSequence(generation)
                try {
                    JPushInterface.deleteAlias(context, sequence)
                    DiagnosticLogStore.info(
                        context,
                        source = "推送",
                        type = "Alias 删除重试执行",
                        summary = "已发起第 ${retryCount + 1} 次删除重试",
                        detail = "gen=$generation sequence=$sequence",
                    )
                } catch (e: Exception) {
                    // SDK 调用异常，继续安排下一次重试
                    DiagnosticLogStore.warning(
                        context,
                        source = "推送",
                        type = "Alias 删除重试异常",
                        summary = "deleteAlias 调用异常，继续重试",
                        detail = "gen=$generation error=${e.message}",
                    )
                    scheduledDeleteGenerations.remove(generation)
                    scheduleDeleteRetry(context, generation)
                }
            }, delay)
        }

        /** 安排恢复重试 */
        fun scheduleRestoreRetry(
            context: Context,
            generation: Int,
        ) {
            if (!scheduledRestoreGenerations.add(generation)) return

            val retryCount = restoreRetries.getOrDefault(generation, 0)
            if (retryCount >= MAX_RETRIES) {
                DiagnosticLogStore.warning(
                    context,
                    source = "推送",
                    type = "Alias 恢复放弃",
                    summary = "Alias 恢复重试 $MAX_RETRIES 次后仍失败，等待下次协调",
                    detail = "gen=$generation",
                )
                restoreRetries.remove(generation)
                scheduledRestoreGenerations.remove(generation)
                return
            }

            val delay = RETRY_DELAYS[retryCount]
            restoreRetries[generation] = retryCount + 1

            DiagnosticLogStore.info(
                context,
                source = "推送",
                type = "Alias 恢复重试安排",
                summary = "将在 ${delay}ms 后第 ${retryCount + 1} 次重试恢复",
                detail = "gen=$generation",
            )

            retryHandler.postDelayed({
                // 释放“已调度”标记，允许后续异步失败继续安排重试
                scheduledRestoreGenerations.remove(generation)

                val currentState =
                    KeepAliveForegroundService.getAliasState(context)
                val currentGen =
                    KeepAliveForegroundService.getAliasGeneration(context)
                val hasToken =
                    KeepAliveForegroundService.hasAuthToken(context)
                val currentAlias =
                    KeepAliveForegroundService.getStoredAlias(context)

                if (currentState != "active"
                    || currentGen != generation
                    || !hasToken
                    || currentAlias.isNullOrBlank()) {
                    DiagnosticLogStore.info(
                        context,
                        source = "推送",
                        type = "Alias 恢复取消",
                        summary = "状态/generation/登录状态已变化，取消恢复重试",
                        detail = "state=$currentState gen=$currentGen hasToken=$hasToken",
                    )
                    restoreRetries.remove(generation)
                    return@postDelayed
                }

                val sequence = restoreSequence(generation)
                try {
                    JPushInterface.setAlias(context, sequence, currentAlias)
                    DiagnosticLogStore.info(
                        context,
                        source = "推送",
                        type = "Alias 恢复重试执行",
                        summary = "已发起第 ${retryCount + 1} 次恢复重试",
                        detail = "gen=$generation sequence=$sequence",
                    )
                } catch (e: Exception) {
                    DiagnosticLogStore.warning(
                        context,
                        source = "推送",
                        type = "Alias 恢复重试异常",
                        summary = "setAlias 调用异常，继续重试",
                        detail = "gen=$generation error=${e.message}",
                    )
                    scheduleRestoreRetry(context, generation)
                }
            }, delay)
        }
    }

    override fun isNeedShowNotification(
        context: Context,
        notificationMessage: NotificationMessage,
        processName: String,
    ): Boolean {
        val conversationId = conversationIdFrom(notificationMessage)
            ?: return super.isNeedShowNotification(context, notificationMessage, processName)

        if (PrivateMessageNotificationState.isActiveConversationForeground(context, conversationId)) {
            return false
        }

        return super.isNeedShowNotification(context, notificationMessage, processName)
    }

    override fun onNotifyMessageArrived(
        context: Context,
        notificationMessage: NotificationMessage,
    ) {
        val conversationId = conversationIdFrom(notificationMessage)

        if (conversationId != null &&
            notificationMessage.notificationId > 0) {
            PrivateMessageNotificationStore.record(
                context,
                conversationId,
                notificationMessage.notificationId,
            )
        }

        super.onNotifyMessageArrived(context, notificationMessage)
    }

    override fun onNotifyMessageOpened(
        context: Context,
        notificationMessage: NotificationMessage,
    ) {
        val extras = notificationMessage.notificationExtras.orEmpty()
        val json = try {
            JSONObject(extras)
        } catch (_: Exception) {
            null
        }

        val isPrivateMessage =
            json?.optString("type") == "private_message"

        val conversationId =
            json?.optString("conversation_id")?.toLongOrNull()

        if (!isPrivateMessage || conversationId == null) {
            super.onNotifyMessageOpened(context, notificationMessage)
            return
        }

        PrivateMessageNotificationStore.clear(
            context,
            conversationId,
        )

        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_PRIVATE_MESSAGE
            putExtra(
                MainActivity.EXTRA_PRIVATE_MESSAGE_JSON,
                extras,
            )
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }

        context.startActivity(intent)
    }

    override fun onRegister(
        context: Context,
        registrationId: String,
    ) {
        super.onRegister(context, registrationId)
        if (registrationId.isNotBlank()) {
            DiagnosticLogStore.info(
                context,
                source = "推送",
                type = "JPush 注册",
                summary = "RegistrationID 已获取，触发 Alias 协调",
                detail = "rid=***${registrationId.takeLast(6)}",
            )
            requestReconcile(context)
        }
    }

    override fun onConnected(
        context: Context,
        isConnected: Boolean,
    ) {
        super.onConnected(context, isConnected)
        if (isConnected) {
            DiagnosticLogStore.info(
                context,
                source = "推送",
                type = "JPush 重连",
                summary = "极光长连接已恢复，触发 Alias 协调",
            )
            requestReconcile(context)
        }
    }

    override fun onNotifyMessageDismiss(
        context: Context,
        notificationMessage: NotificationMessage,
    ) {
        val conversationId = conversationIdFrom(notificationMessage)
        val notificationId = notificationMessage.notificationId

        if (conversationId != null && notificationId > 0) {
            PrivateMessageNotificationStore.remove(
                context,
                conversationId,
                notificationId,
            )
        }

        super.onNotifyMessageDismiss(context, notificationMessage)
    }

    override fun onAliasOperatorResult(
        context: Context,
        jPushMessage: JPushMessage,
    ) {
        // 父类只调用一次，保证 Flutter 插件正常收到结果
        super.onAliasOperatorResult(context, jPushMessage)

        val appContext = context.applicationContext

        if (Looper.myLooper() == Looper.getMainLooper()) {
            handleAliasOperatorResult(appContext, jPushMessage)
        } else {
            retryHandler.post {
                handleAliasOperatorResult(appContext, jPushMessage)
            }
        }
    }

    private fun handleAliasOperatorResult(
        context: Context,
        jPushMessage: JPushMessage,
    ) {
        val sequence = jPushMessage.sequence

        when {
            isDeleteSequence(sequence) -> {
                val gen = generationFromSequence(sequence)
                if (jPushMessage.errorCode == 0) {
                    // 远端删除成功：generation 匹配且 state=pending_delete 才清除本地
                    val cleared = KeepAliveForegroundService
                        .clearStoredAliasIfPendingDelete(context, gen)
                    // 无论是否真正清除，旧 generation 的重试记录都清理
                    deleteRetries.remove(gen)
                    scheduledDeleteGenerations.remove(gen)

                    if (cleared) {
                        DiagnosticLogStore.info(
                            context,
                            source = "推送",
                            type = "Alias 删除成功",
                            summary = "极光 Alias 已删除，本地存储已清除",
                            detail = "gen=$gen sequence=$sequence",
                        )
                    } else {
                        DiagnosticLogStore.info(
                            context,
                            source = "推送",
                            type = "Alias 删除过期",
                            summary = "删除回调到达但 generation/state 不匹配，已忽略",
                            detail = "gen=$gen sequence=$sequence",
                        )
                    }
                } else {
                    // 删除失败，安排重试
                    DiagnosticLogStore.warning(
                        context,
                        source = "推送",
                        type = "Alias 删除失败",
                        summary = "极光 Alias 删除失败，安排退避重试",
                        detail = "code=${jPushMessage.errorCode} gen=$gen",
                    )
                    scheduleDeleteRetry(context, gen)
                }
            }

            isRestoreSequence(sequence) -> {
                val requestGen = generationFromSequence(sequence)
                if (jPushMessage.errorCode == 0) {
                    val currentState =
                        KeepAliveForegroundService.getAliasState(context)
                    val currentGen =
                        KeepAliveForegroundService.getAliasGeneration(context)

                    val currentAlias =
                        KeepAliveForegroundService.getStoredAlias(context)
                    val callbackAlias = jPushMessage.alias.orEmpty()

                    if (currentState != "active"
                        || currentGen != requestGen
                        || callbackAlias != (currentAlias ?: "")) {
                        restoreRetries.remove(requestGen)
                        scheduledRestoreGenerations.remove(requestGen)
                        val hasToken =
                            KeepAliveForegroundService.hasAuthToken(context)
                        DiagnosticLogStore.warning(
                            context,
                            source = "推送",
                            type = "Alias 恢复过期",
                            summary = "setAlias 回调已过期" +
                                if (!hasToken) "（无登录状态，极光可能已绑定旧账号）" else "",
                            detail = "reqGen=$requestGen curState=$currentState curGen=$currentGen hasToken=$hasToken",
                        )
                        // 无登录状态 + 过期回调 = 旧账号可能已被远端重新绑定 → 触发清理
                        if (!hasToken) {
                            KeepAliveForegroundService
                                .ensureAliasPendingDelete(context)
                        }
                        KeepAliveForegroundService.reconcileAliasState(context)
                        return
                    }

                    restoreRetries.remove(requestGen)
                    scheduledRestoreGenerations.remove(requestGen)
                    DiagnosticLogStore.info(
                        context,
                        source = "推送",
                        type = "Alias 恢复成功",
                        summary = "保活服务 Alias 绑定成功",
                        detail = "sequence=$sequence gen=$requestGen",
                    )
                } else {
                    DiagnosticLogStore.warning(
                        context,
                        source = "推送",
                        type = "Alias 恢复失败",
                        summary = "保活服务 Alias 绑定失败，安排退避重试",
                        detail = "code=${jPushMessage.errorCode} sequence=$sequence",
                    )
                    scheduleRestoreRetry(context, requestGen)
                }
            }

            else -> {
                if (jPushMessage.errorCode == 0) {
                    DiagnosticLogStore.info(
                        context,
                        source = "推送",
                        type = "Alias 操作成功",
                        summary = "Alias 操作完成",
                        detail = "sequence=$sequence",
                    )
                } else {
                    DiagnosticLogStore.warning(
                        context,
                        source = "推送",
                        type = "Alias 操作失败",
                        summary = "Alias 操作失败",
                        detail = "code=${jPushMessage.errorCode} sequence=$sequence",
                    )
                }
            }
        }
    }

    private fun conversationIdFrom(notificationMessage: NotificationMessage): Long? {
        val extras = notificationMessage.notificationExtras ?: return null
        return try {
            JSONObject(extras).optString("conversation_id").toLongOrNull()
        } catch (_: Exception) {
            null
        }
    }
}
