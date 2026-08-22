import 'package:flutter/material.dart';

import '../../models/ai_run_event.dart';
import '../../theme/app_motion.dart';
import '../campus/campus_theme.dart';

/// 将设备桥接的技术状态翻译成用户能理解的执行进度。
class AiAgentExecutionCard extends StatelessWidget {
  const AiAgentExecutionCard({
    super.key,
    required this.event,
    this.onOpenPermissions,
  });

  final AiRunEvent? event;
  final VoidCallback? onOpenPermissions;

  @override
  Widget build(BuildContext context) {
    final current = event;
    if (current == null || !_isDeviceFlow(current.type)) {
      return const SizedBox.shrink();
    }
    final stage = _stage(current.type);
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final waiting = current.type == AiRunEventType.consentRequired;
    return AnimatedSize(
      duration: AppMotion.duration(context, AppMotion.fast),
      curve: AppMotion.standard,
      child: Container(
        key: const ValueKey('ai-agent-execution-card'),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isDark ? colors.surfaceContainer : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.05),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: isDark
                          ? colors.primaryContainer
                          : CampusTheme.primaryLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      waiting
                          ? Icons.touch_app_outlined
                          : Icons.auto_awesome_rounded,
                      color: colors.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('校园 Agent 正在获取最新数据',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                        SizedBox(height: 3),
                        Text('只在需要时唤醒手机，完成后会自动继续回答',
                            style: TextStyle(fontSize: 11, height: 1.35)),
                      ],
                    ),
                  ),
                  if (waiting)
                    TextButton(
                      onPressed: onOpenPermissions,
                      child: const Text('权限'),
                    )
                  else
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.28),
                border: Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              child: Column(
                children: [
                  _StepRow(
                    title: '检查数据新鲜度',
                    detail: _datasetLabel(current.datasets),
                    state: stage >= 1 ? _StepState.done : _StepState.running,
                  ),
                  _StepRow(
                    title: stage >= 2 ? '手机已接受任务' : '创建 MCP 设备任务',
                    detail: stage >= 2 ? '设备桥接在线' : '等待设备响应',
                    state: stage == 2
                        ? _StepState.running
                        : stage > 2
                            ? _StepState.done
                            : _StepState.pending,
                  ),
                  _StepRow(
                    title: stage >= 3 ? '设备正在执行' : '刷新或读取本地数据',
                    detail: current.type == AiRunEventType.eduFetching
                        ? '正在通过已有教务会话刷新'
                        : '凭据和原始缓存保留在设备上',
                    state: stage == 3
                        ? _StepState.running
                        : stage > 3
                            ? _StepState.done
                            : _StepState.pending,
                  ),
                  _StepRow(
                    title: stage >= 4 ? '摘要已回传，AI 已继续' : '回传最小化摘要',
                    detail:
                        stage >= 4 ? '不会上传密码、Cookie 或 Token' : '只返回当前问题需要的字段',
                    state: stage == 4 ? _StepState.running : _StepState.pending,
                    last: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static bool _isDeviceFlow(AiRunEventType type) => switch (type) {
        AiRunEventType.deviceWaiting ||
        AiRunEventType.deviceClaimed ||
        AiRunEventType.eduFetching ||
        AiRunEventType.toolCompleted ||
        AiRunEventType.consentRequired =>
          true,
        _ => false,
      };

  static int _stage(AiRunEventType type) => switch (type) {
        AiRunEventType.consentRequired || AiRunEventType.deviceWaiting => 1,
        AiRunEventType.deviceClaimed => 2,
        AiRunEventType.eduFetching => 3,
        AiRunEventType.toolCompleted => 4,
        _ => 0,
      };

  static String _datasetLabel(List<String> datasets) {
    if (datasets.contains('grades')) return '成绩 · 新鲜度由设备最终确认';
    if (datasets.contains('schedule')) return '课表 · 只在过期时刷新';
    if (datasets.contains('erke')) return '二课 · 仅返回结构化摘要';
    return '成绩、课表或二课';
  }
}

enum _StepState { pending, running, done }

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.title,
    required this.detail,
    required this.state,
    this.last = false,
  });

  final String title;
  final String detail;
  final _StepState state;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (state) {
      _StepState.done => CampusTheme.green,
      _StepState.running => colors.primary,
      _StepState.pending => colors.outline,
    };
    return SizedBox(
      height: 42,
      child: Stack(
        children: [
          if (!last)
            Positioned(
              left: 9,
              top: 20,
              bottom: 0,
              child: Container(width: 1, color: colors.outlineVariant),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 19,
                height: 19,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(
                      alpha: state == _StepState.pending ? 0.10 : 0.14),
                  shape: BoxShape.circle,
                ),
                child: state == _StepState.done
                    ? Icon(Icons.check_rounded, size: 12, color: color)
                    : state == _StepState.running
                        ? SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.6, color: color),
                          )
                        : Text('·',
                            style: TextStyle(
                                color: color, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(detail,
                        style: TextStyle(
                            fontSize: 10.5, color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
