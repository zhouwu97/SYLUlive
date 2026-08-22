import 'package:flutter/material.dart';

import '../../models/ai_run_event.dart';
import '../../theme/app_motion.dart';
import '../campus/campus_theme.dart';

/// 绑定到触发它的用户消息下方的 Agent 过程条。
///
/// 默认只显示一行摘要；只有用户展开或需要授权时才展示完整步骤。
class AiAgentExecutionCard extends StatefulWidget {
  const AiAgentExecutionCard({
    super.key,
    required this.event,
    this.completed = false,
    this.onOpenPermissions,
    this.onAllowOnce,
    this.onAllowAlways,
    this.onDeny,
  });

  final AiRunEvent? event;
  final bool completed;
  final VoidCallback? onOpenPermissions;
  final VoidCallback? onAllowOnce;
  final VoidCallback? onAllowAlways;
  final VoidCallback? onDeny;

  @override
  State<AiAgentExecutionCard> createState() => _AiAgentExecutionCardState();
}

class _AiAgentExecutionCardState extends State<AiAgentExecutionCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant AiAgentExecutionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.event?.type == AiRunEventType.consentRequired &&
        oldWidget.event?.type != AiRunEventType.consentRequired) {
      _expanded = true;
    } else if (oldWidget.event?.type == AiRunEventType.consentRequired &&
        widget.event?.type != AiRunEventType.consentRequired) {
      _expanded = false;
    } else if (widget.completed && !oldWidget.completed) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    if (event == null || !_isAgentFlow(event.type)) {
      return const SizedBox.shrink();
    }
    final waiting = event.type == AiRunEventType.consentRequired;
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = widget.completed
        ? '已使用最新数据'
        : waiting
            ? '需要你的许可来获取最新数据'
            : '正在检查需要的数据';
    final detail = widget.completed
        ? '${_datasetLabel(event.datasets)} · Agent 已自动继续回答'
        : waiting
            ? '只读取本次问题需要的最小化摘要'
            : '只在需要时唤醒设备或刷新教务数据';

    return AnimatedSize(
      duration: AppMotion.duration(context, AppMotion.fast),
      curve: AppMotion.standard,
      child: Container(
        key: const ValueKey('ai-agent-execution-card'),
        margin: const EdgeInsets.only(top: 2, bottom: 10),
        decoration: BoxDecoration(
          color: isDark ? colors.surfaceContainer : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: waiting
                ? colors.primary.withValues(alpha: 0.55)
                : colors.outlineVariant,
          ),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Semantics(
              button: true,
              label: '$title。$detail',
              hint: _expanded ? '点击收起 Agent 执行详情' : '点击展开 Agent 执行详情',
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: Row(
                    children: [
                      _StatusIcon(
                        completed: widget.completed,
                        waiting: waiting,
                        colors: colors,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (waiting && widget.onOpenPermissions != null)
                        TextButton(
                          onPressed: widget.onOpenPermissions,
                          child: const Text('权限设置'),
                        ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: waiting
                    ? _PermissionPanel(
                        reason: event.consentReason,
                        onAllowOnce: widget.onAllowOnce,
                        onAllowAlways: widget.onAllowAlways,
                        onDeny: widget.onDeny,
                      )
                    : _DetailsPanel(
                        event: event,
                        completed: widget.completed,
                      ),
              ),
          ],
        ),
      ),
    );
  }

  static bool _isAgentFlow(AiRunEventType type) => switch (type) {
        AiRunEventType.toolRequested ||
        AiRunEventType.toolExecuting ||
        AiRunEventType.deviceWaiting ||
        AiRunEventType.deviceClaimed ||
        AiRunEventType.consentRequired ||
        AiRunEventType.eduFetching ||
        AiRunEventType.toolCompleted =>
          true,
        _ => false,
      };

  static String _datasetLabel(List<String> datasets) {
    if (datasets.contains('grades') || datasets.contains('academic')) {
      return '成绩';
    }
    if (datasets.contains('schedule')) return '课表';
    if (datasets.contains('erke')) return '二课';
    return '相关校园数据';
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
    required this.completed,
    required this.waiting,
    required this.colors,
  });

  final bool completed;
  final bool waiting;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final color = completed ? CampusTheme.green : colors.primary;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: completed
          ? Icon(Icons.check_rounded, color: color, size: 18)
          : waiting
              ? Icon(Icons.touch_app_outlined, color: color, size: 18)
              : SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
    );
  }
}

class _PermissionPanel extends StatelessWidget {
  const _PermissionPanel({
    required this.reason,
    this.onAllowOnce,
    this.onAllowAlways,
    this.onDeny,
  });

  final String reason;
  final VoidCallback? onAllowOnce;
  final VoidCallback? onAllowAlways;
  final VoidCallback? onDeny;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          reason.trim().isEmpty ? '当前数据不够新，Agent 需要先检查并刷新校园数据。' : reason.trim(),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 10),
        _PermissionLine(
          icon: Icons.refresh_rounded,
          text: '必要时刷新成绩、课表或二课数据',
          colors: colors,
        ),
        _PermissionLine(
          icon: Icons.lock_outline_rounded,
          text: '只回传本次问题所需摘要，不上传密码、Cookie 或 Token',
          colors: colors,
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: onDeny,
              child: const Text('不允许'),
            ),
            TextButton(
              onPressed: onAllowAlways,
              child: const Text('今后自动执行'),
            ),
            FilledButton(
              onPressed: onAllowOnce,
              child: const Text('仅本次允许'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PermissionLine extends StatelessWidget {
  const _PermissionLine({
    required this.icon,
    required this.text,
    required this.colors,
  });

  final IconData icon;
  final String text;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.event, required this.completed});

  final AiRunEvent event;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final stage = _stage(event.type, completed);
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          _StepRow(
            title: '检查数据新鲜度',
            detail: '确认${_datasetLabel(event.datasets)}是否仍在可接受时间内',
            state: stage >= 1 ? _StepState.done : _StepState.running,
          ),
          _StepRow(
            title: stage >= 2 ? '创建 MCP 设备任务' : '准备所需数据',
            detail: stage >= 2 ? '任务只携带工具名和最小参数' : 'Agent 正在计算需要哪些字段',
            state: stage == 2
                ? _StepState.running
                : stage > 2
                    ? _StepState.done
                    : _StepState.pending,
          ),
          _StepRow(
            title: stage >= 3 ? '设备正在执行' : '等待设备或教务刷新',
            detail: event.type == AiRunEventType.eduFetching
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
            detail: '只返回当前问题需要的字段',
            state: stage >= 4 ? _StepState.done : _StepState.pending,
            last: true,
          ),
        ],
      ),
    );
  }

  static int _stage(AiRunEventType type, bool completed) {
    if (completed || type == AiRunEventType.toolCompleted) return 4;
    return switch (type) {
      AiRunEventType.toolRequested || AiRunEventType.toolExecuting => 1,
      AiRunEventType.deviceWaiting || AiRunEventType.consentRequired => 2,
      AiRunEventType.deviceClaimed || AiRunEventType.eduFetching => 3,
      _ => 1,
    };
  }

  static String _datasetLabel(List<String> datasets) {
    if (datasets.contains('grades') || datasets.contains('academic')) {
      return '成绩';
    }
    if (datasets.contains('schedule')) return '课表';
    if (datasets.contains('erke')) return '二课';
    return '相关校园数据';
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 42),
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
                    alpha: state == _StepState.pending ? 0.10 : 0.14,
                  ),
                  shape: BoxShape.circle,
                ),
                child: state == _StepState.done
                    ? Icon(Icons.check_rounded, size: 12, color: color)
                    : state == _StepState.running
                        ? SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: color,
                            ),
                          )
                        : Text(
                            '·',
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
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
