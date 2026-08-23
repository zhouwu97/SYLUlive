import 'package:flutter/material.dart';

import '../../models/ai_run_event.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';

/// 校园 Agent 的唯一主流程卡。
///
/// event 为空时也会立即渲染，覆盖 Run 刚建立、第一条 SSE 尚未返回的窗口。
class AiAgentExecutionCard extends StatefulWidget {
  const AiAgentExecutionCard({
    super.key,
    required this.event,
    this.running = false,
    this.completed = false,
    this.onOpenPermissions,
    this.onAllowOnce,
    this.onAllowAlways,
    this.onDeny,
  });

  final AiRunEvent? event;
  final bool running;
  final bool completed;
  final VoidCallback? onOpenPermissions;
  // 保留旧调用面的兼容性；长期授权只在权限 Bottom Sheet 中修改。
  final VoidCallback? onAllowOnce;
  final VoidCallback? onAllowAlways;
  final VoidCallback? onDeny;

  @override
  State<AiAgentExecutionCard> createState() => _AiAgentExecutionCardState();
}

class _AiAgentExecutionCardState extends State<AiAgentExecutionCard> {
  // Agent 开始工作时先把过程讲清楚；只有正常完成才自动收起。
  bool _expanded = true;

  @override
  void didUpdateWidget(covariant AiAgentExecutionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final startedNewRun = widget.running &&
        (!oldWidget.running || widget.event?.runId != oldWidget.event?.runId);
    if (startedNewRun ||
        widget.event?.type == AiRunEventType.consentRequired ||
        widget.event?.type == AiRunEventType.failed ||
        widget.event?.type == AiRunEventType.cancelled) {
      _expanded = true;
    } else if (widget.completed && !oldWidget.completed) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    if (!widget.running && !widget.completed && !_isAgentEvent(event?.type)) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final title = _title(event, widget.completed);
    final detail = _detail(event, widget.completed);
    final stage = _stage(event?.type, widget.completed);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedSize(
      duration: AppMotion.duration(context, AppMotion.fast),
      curve: AppMotion.standard,
      child: Container(
        key: const ValueKey('ai-agent-execution-card'),
        margin: const EdgeInsets.only(top: 2, bottom: 10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: widget.completed
                ? AppColors.success.withValues(alpha: 0.35)
                : isDark
                    ? AppColors.borderNormalDark
                    : AppColors.borderNormalLight,
          ),
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
                      _AgentMark(completed: widget.completed),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(detail,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: colors.onSurfaceVariant,
                                    height: 1.3)),
                          ],
                        ),
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
                child: _DetailsPanel(
                  event: event,
                  stage: stage,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static bool _isAgentEvent(AiRunEventType? type) => switch (type) {
        AiRunEventType.toolRequested ||
        AiRunEventType.toolExecuting ||
        AiRunEventType.deviceWaiting ||
        AiRunEventType.deviceClaimed ||
        AiRunEventType.consentRequired ||
        AiRunEventType.eduFetching ||
        AiRunEventType.toolCompleted ||
        AiRunEventType.failed ||
        AiRunEventType.cancelled =>
          true,
        _ => false,
      };

  static String _title(AiRunEvent? event, bool completed) {
    if (completed) return '已完成本次数据核对';
    return switch (event?.type) {
      null || AiRunEventType.started || AiRunEventType.status => '正在连接校园 Agent',
      AiRunEventType.deviceWaiting ||
      AiRunEventType.consentRequired =>
        '正在准备设备数据',
      AiRunEventType.deviceClaimed => '正在读取个人数据',
      AiRunEventType.eduFetching =>
        '正在更新${_datasetLabel(event?.datasets ?? const [])}数据',
      AiRunEventType.toolCompleted => '数据已准备，正在继续回答',
      AiRunEventType.failed => 'Agent 处理未完成',
      AiRunEventType.cancelled => '本次处理已取消',
      _ => '正在检查需要的数据',
    };
  }

  static String _detail(AiRunEvent? event, bool completed) {
    if (completed) {
      return '已完成${_datasetLabel(event?.datasets ?? const [])}数据处理，回答仅使用已核验结果';
    }
    return switch (event?.type) {
      null || AiRunEventType.started => '正在建立安全会话',
      AiRunEventType.deviceWaiting ||
      AiRunEventType.consentRequired =>
        event?.consentReason.trim().isNotEmpty == true
            ? event!.consentReason.trim()
            : '${_datasetLabel(event?.datasets ?? const [])} 数据需要更新',
      AiRunEventType.deviceClaimed => '只处理当前问题需要字段',
      AiRunEventType.eduFetching => '使用现有教务授权会话',
      AiRunEventType.toolCompleted => 'Agent 已恢复原来的任务',
      AiRunEventType.failed => '已保留执行过程，下面会显示失败原因',
      AiRunEventType.cancelled => '执行过程已停止',
      _ => _datasetLabel(event?.datasets ?? const []),
    };
  }

  static int _stage(AiRunEventType? type, bool completed) {
    if (completed) return 5;
    return switch (type) {
      null || AiRunEventType.started || AiRunEventType.status => 1,
      AiRunEventType.toolRequested || AiRunEventType.toolExecuting => 1,
      AiRunEventType.deviceWaiting || AiRunEventType.consentRequired => 2,
      AiRunEventType.deviceClaimed || AiRunEventType.eduFetching => 3,
      AiRunEventType.toolCompleted => 4,
      _ => 1,
    };
  }

  static String _datasetLabel(List<String> datasets) {
    if (datasets.contains('grades') || datasets.contains('academic')) {
      return '成绩';
    }
    if (datasets.contains('schedule')) return '课表';
    if (datasets.contains('erke')) return '二课';
    return '课表 · 成绩';
  }
}

class _AgentMark extends StatelessWidget {
  const _AgentMark({required this.completed});

  final bool completed;

  @override
  Widget build(BuildContext context) {
    return Icon(
      completed
          ? Icons.check_circle_outline_rounded
          : Icons.auto_awesome_rounded,
      size: 20,
      color: completed ? AppColors.success : AppColors.brandPrimary,
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.event, required this.stage});

  final AiRunEvent? event;
  final int stage;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dataLabel = _dataLabel(event?.datasets ?? const []);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceMutedDark : const Color(0xFFF8FBF8),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        children: [
          _StepRow(
              title: '检查服务端快照', detail: '$dataLabel · 已检查来源', state: _state(1)),
          _StepRow(
              title: '判断是否需要设备',
              detail: stage >= 2 ? '当前问题要求最新数据' : '先判断数据新鲜度',
              state: _state(2)),
          _StepRow(title: '读取或更新个人数据', detail: '只处理当前问题需要字段', state: _state(3)),
          _StepRow(
              title: '恢复 AI 回答',
              detail: stage >= 4 ? '完成后自动继续原 Run' : '等待数据准备完成',
              state: _state(4),
              last: true),
        ],
      ),
    );
  }

  _StepState _state(int number) {
    if (stage > number) return _StepState.done;
    if (stage == number) return _StepState.running;
    return _StepState.pending;
  }

  String _dataLabel(List<String> datasets) {
    if (datasets.contains('grades') || datasets.contains('academic')) {
      return '成绩';
    }
    if (datasets.contains('schedule')) return '课表';
    if (datasets.contains('erke')) return '二课';
    return '课表 · 成绩';
  }
}

enum _StepState { pending, running, done }

class _StepRow extends StatelessWidget {
  const _StepRow(
      {required this.title,
      required this.detail,
      required this.state,
      this.last = false});

  final String title;
  final String detail;
  final _StepState state;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.done => AppColors.success,
      _StepState.running => AppColors.brandPrimary,
      _StepState.pending => Theme.of(context).colorScheme.outline,
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
                child: Container(width: 1, color: AppColors.borderNormalLight)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 19,
                height: 19,
                child: Center(
                  child: state == _StepState.done
                      ? Icon(Icons.check_rounded, size: 14, color: color)
                      : state == _StepState.running
                          ? Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                  color: color, shape: BoxShape.circle))
                          : Text('○',
                              style: TextStyle(color: color, fontSize: 14)),
                ),
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
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondaryLight)),
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
