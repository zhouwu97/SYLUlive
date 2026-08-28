import 'package:flutter/material.dart';

import '../../models/ai_agent_activity.dart';
import '../../models/ai_agent_activity_reducer.dart';
import '../../models/ai_run_event.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';

/// 展示 SSE 真实产生的 Agent activity；收起态是摘要，展开态保留完整审计过程。
class AiAgentExecutionCard extends StatefulWidget {
  const AiAgentExecutionCard({
    super.key,
    this.activities = const <AiAgentActivity>[],
    this.rawEvents = const <AiRunEvent>[],
    this.event,
    this.running = false,
    this.completed = false,
    this.onOpenPermissions,
    this.onAllowOnce,
    this.onAllowAlways,
    this.onDeny,
    this.onRetryRefresh,
    this.onUseExistingData,
    this.onReauthorizeEdu,
    this.onUpdateErke,
  });

  final List<AiAgentActivity> activities;
  final List<AiRunEvent> rawEvents;
  // 兼容旧调用面；新页面应传 activities。
  final AiRunEvent? event;
  final bool running;
  final bool completed;
  final VoidCallback? onOpenPermissions;
  final VoidCallback? onAllowOnce;
  final VoidCallback? onAllowAlways;
  final VoidCallback? onDeny;
  final VoidCallback? onRetryRefresh;
  final VoidCallback? onUseExistingData;
  final VoidCallback? onReauthorizeEdu;
  final VoidCallback? onUpdateErke;

  @override
  State<AiAgentExecutionCard> createState() => _AiAgentExecutionCardState();
}

class _AiAgentExecutionCardState extends State<AiAgentExecutionCard> {
  bool _expanded = true;
  bool _showTechnicalDetails = false;

  List<AiAgentActivity> get _activities {
    if (widget.activities.isNotEmpty) return widget.activities;
    final event = widget.event;
    if (event == null) return const <AiAgentActivity>[];
    return AiAgentActivityReducer.reduce(<AiRunEvent>[event],
        completed: widget.completed);
  }

  List<AiAgentActivity> get _rawActivities {
    if (widget.rawEvents.isNotEmpty) {
      return AiAgentActivityReducer.reduceRaw(widget.rawEvents);
    }
    return _activities;
  }

  @override
  void didUpdateWidget(covariant AiAgentExecutionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newRun = widget.event?.runId != oldWidget.event?.runId;
    if (newRun || (widget.running && !oldWidget.running)) {
      _expanded = true;
      _showTechnicalDetails = false;
    } else if (widget.completed && !oldWidget.completed) {
      _expanded = false;
    }
    if (_activities
        .any((item) => item.status == AiAgentActivityStatus.failed)) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activities = _activities;
    final rawActivities = _rawActivities;
    if (!widget.running && !widget.completed && activities.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final latest = activities.isEmpty ? null : activities.last;
    final title = widget.completed
        ? '已完成分析'
        : latest?.title ?? (widget.running ? '正在处理当前问题…' : 'Agent 过程');
    final detail = latest?.detail ?? '';
    final isError = latest?.status == AiAgentActivityStatus.failed;
    final refreshFailed = activities.any(
      (item) =>
          item.code == 'refresh_failed' ||
          item.code == 'device_job_failed' ||
          item.errorCode == 'refresh_incomplete' ||
          item.errorCode == 'device_refresh_not_fresh' ||
          item.errorCode == 'network_unavailable' ||
          _isEduRecoveryCode(item.errorCode, item.toolName),
    );
    final needsEduRecovery = activities.any(
      (item) => _isEduRecoveryCode(item.errorCode, item.toolName),
    );
    final compactActivities = activities.length <= 3
        ? activities
        : activities.sublist(activities.length - 3);
    final showFullProcessButton =
        !_expanded && widget.rawEvents.isNotEmpty && rawActivities.isNotEmpty;
    final showTechnicalDetailsButton =
        _expanded && widget.rawEvents.isNotEmpty && rawActivities.isNotEmpty;

    return AnimatedSize(
      duration: AppMotion.duration(context, AppMotion.fast),
      curve: AppMotion.standard,
      child: Container(
        key: const ValueKey('ai-agent-execution-card'),
        margin: const EdgeInsets.only(top: 2, bottom: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceSecondaryDark
              : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isError
                ? AppColors.danger.withValues(alpha: 0.4)
                : colors.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Semantics(
              button: true,
              label: '$title。$detail',
              hint: _expanded
                  ? '点击收起 Agent 过程'
                  : showFullProcessButton
                      ? '点击查看完整过程'
                      : '点击展开 Agent 过程',
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
                  child: Row(
                    children: [
                      _ActivityMark(
                        activity: latest,
                        completed: widget.completed,
                        running: widget.running,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700)),
                            if (detail.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(detail,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: colors.onSurfaceVariant,
                                      height: 1.3)),
                            ],
                          ],
                        ),
                      ),
                      Icon(
                        _expanded
                            ? (_showTechnicalDetails
                                ? Icons.subject_rounded
                                : Icons.keyboard_arrow_up_rounded)
                            : Icons.keyboard_arrow_down_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (activities.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: _ActivityList(
                  activities: _showTechnicalDetails
                      ? rawActivities
                      : _expanded
                          ? activities
                          : compactActivities,
                ),
              ),
            if (showFullProcessButton || (!_expanded && activities.length > 3))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = true),
                  child: const Text('查看完整过程'),
                ),
              ),
            if (showTechnicalDetailsButton)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(
                      () => _showTechnicalDetails = !_showTechnicalDetails),
                  child: Text(
                    _showTechnicalDetails ? '收起技术详情' : '查看技术详情',
                  ),
                ),
              ),
            if (refreshFailed &&
                isError &&
                (widget.onRetryRefresh != null ||
                    widget.onUseExistingData != null ||
                    widget.onReauthorizeEdu != null))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (needsEduRecovery && widget.onReauthorizeEdu != null)
                      TextButton(
                        onPressed: widget.onReauthorizeEdu,
                        child: const Text('重新验证教务'),
                      ),
                    if (widget.onUseExistingData != null)
                      TextButton(
                        onPressed: widget.onUseExistingData,
                        child: const Text('使用已有数据'),
                      ),
                    if (widget.onRetryRefresh != null)
                      FilledButton.tonal(
                        onPressed: widget.onRetryRefresh,
                        child: const Text('重新获取'),
                      ),
                  ],
                ),
              ),
            if (widget.onUpdateErke != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: widget.onUpdateErke,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('更新二课数据'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static bool _isEduRecoveryCode(String code, String toolName) {
    switch (code.trim().toLowerCase()) {
      case 'edu_authorization_revoked':
      case 'edu_session_logged_out':
      case 'edu_session_expired':
      case 'edu_credential_unavailable':
      case 'credential_unavailable':
        return toolName.contains('academic') || toolName.contains('schedule');
      default:
        return false;
    }
  }
}

class _ActivityMark extends StatelessWidget {
  const _ActivityMark({
    this.activity,
    required this.completed,
    required this.running,
  });

  final AiAgentActivity? activity;
  final bool completed;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final status = activity?.status;
    if (running && !completed && status != AiAgentActivityStatus.failed) {
      return const AiThinkingIndicator(size: 20);
    }
    final icon = completed || status == AiAgentActivityStatus.success
        ? Icons.check_circle_outline_rounded
        : status == AiAgentActivityStatus.failed
            ? Icons.error_outline_rounded
            : Icons.auto_awesome_rounded;
    final color = status == AiAgentActivityStatus.failed
        ? AppColors.danger
        : completed || status == AiAgentActivityStatus.success
            ? AppColors.success
            : AppColors.brandPrimary;
    return Icon(icon, size: 20, color: color);
  }
}

/// 低频的 Agent 运行反馈。它只改变图标的透明度和缩放，不参与布局，
/// 并在系统关闭动画时退化为静态图标。
class AiThinkingIndicator extends StatefulWidget {
  const AiThinkingIndicator({
    super.key,
    this.size = 16,
    this.color = AppColors.brandPrimary,
  });

  final double size;
  final Color color;

  @override
  State<AiThinkingIndicator> createState() => _AiThinkingIndicatorState();
}

class _AiThinkingIndicatorState extends State<AiThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool? _reducedMotion;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.normal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion == reducedMotion) return;
    _reducedMotion = reducedMotion;
    if (reducedMotion) {
      _controller
        ..stop()
        ..value = 1;
    } else {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = ExcludeSemantics(
      child: Icon(
        Icons.auto_awesome_rounded,
        size: widget.size,
        color: widget.color,
      ),
    );
    if (_reducedMotion ?? MediaQuery.disableAnimationsOf(context)) {
      return KeyedSubtree(
        key: const ValueKey('ai-thinking-indicator-static'),
        child: icon,
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = Curves.easeInOut.transform(_controller.value);
        return Opacity(
          opacity: 0.58 + 0.42 * value,
          child: Transform.scale(
            scale: 0.9 + 0.1 * value,
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: const ValueKey('ai-thinking-indicator-animated'),
        child: icon,
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.activities});

  final List<AiAgentActivity> activities;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: activities
          .map((activity) => _ActivityRow(activity: activity))
          .toList(growable: false),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity});

  final AiAgentActivity activity;

  @override
  Widget build(BuildContext context) {
    final color = switch (activity.status) {
      AiAgentActivityStatus.success => AppColors.success,
      AiAgentActivityStatus.failed => AppColors.danger,
      AiAgentActivityStatus.running => AppColors.brandPrimary,
      AiAgentActivityStatus.pending => Theme.of(context).colorScheme.outline,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Center(
              child: activity.status == AiAgentActivityStatus.running
                  ? AiThinkingIndicator(size: 16, color: color)
                  : Icon(
                      switch (activity.status) {
                        AiAgentActivityStatus.success => Icons.check_rounded,
                        AiAgentActivityStatus.failed =>
                          Icons.priority_high_rounded,
                        AiAgentActivityStatus.pending =>
                          Icons.radio_button_unchecked,
                        AiAgentActivityStatus.running => Icons.circle,
                      },
                      size: 16,
                      color: color,
                    ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(activity.title,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
                if (activity.detail.isNotEmpty)
                  Text(activity.detail,
                      style: TextStyle(
                          fontSize: 10.5,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
