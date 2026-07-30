import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/diagnostic_log_entry.dart';
import '../services/diagnostic_log_service.dart';

class DiagnosticLogScreen extends StatefulWidget {
  const DiagnosticLogScreen({super.key});

  @override
  State<DiagnosticLogScreen> createState() => _DiagnosticLogScreenState();
}

class _DiagnosticLogScreenState extends State<DiagnosticLogScreen> {
  List<DiagnosticLogEntry> _logs = const [];
  DiagnosticRuntimeStatus? _runtimeStatus;
  bool _isLoading = true;
  String _level = 'all';
  String _category = 'all';

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final logs = await DiagnosticLogService.instance.getLogs();
      final runtimeStatus =
          await DiagnosticLogService.instance.getRuntimeStatus();
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _runtimeStatus = runtimeStatus;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志读取失败：$error')),
      );
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空诊断记录'),
        content: const Text('确定清空所有诊断记录吗？此操作无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DiagnosticLogService.instance.clearLogs();
    await _loadLogs();
  }

  List<DiagnosticLogEntry> get _filteredLogs => _logs.where((entry) {
        final levelMatches = switch (_level) {
          'error' => entry.isError,
          'warning' => entry.isWarning,
          'info' => entry.isInfo,
          _ => true,
        };
        return levelMatches &&
            (_category == 'all' || entry.category == _category);
      }).toList();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final groups = _DiagnosticGroup.fromEntries(_filteredLogs);
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断中心'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            onPressed: _logs.isEmpty ? null : () => _copyEntries(_logs),
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loadLogs,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _logs.isEmpty ? null : _clearLogs,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadLogs,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  _OverviewBand(logs: _logs, runtimeStatus: _runtimeStatus),
                  const SizedBox(height: 12),
                  _buildFilters(colors),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '事件时间线 · ${groups.length}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 64),
                      child: Center(child: Text('当前筛选下没有诊断事件')),
                    )
                  else
                    ...groups
                        .map((group) => _DiagnosticTimelineItem(group: group)),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _buildFilters(ColorScheme colors) {
    const categories = <(String, String)>[
      ('all', '全部模块'),
      ('app', '应用'),
      ('network', '网络'),
      ('auth', '账号'),
      ('edu', '教务'),
      ('message', '消息'),
      ('storage', '存储'),
      ('navigation', '导航'),
      ('background', '后台'),
      ('device', '设备工具'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('全部')),
              ButtonSegment(value: 'error', label: Text('错误')),
              ButtonSegment(value: 'warning', label: Text('警告')),
              ButtonSegment(value: 'info', label: Text('信息')),
            ],
            selected: {_level},
            showSelectedIcon: false,
            onSelectionChanged: (values) =>
                setState(() => _level = values.first),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: categories.map((item) {
              final selected = _category == item.$1;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(
                  selected: selected,
                  label: Text(item.$2),
                  onSelected: (_) => setState(() => _category = item.$1),
                  side: BorderSide(
                    color: selected ? colors.primary : colors.outlineVariant,
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  void _copyEntries(List<DiagnosticLogEntry> entries) {
    final text =
        entries.map(_formatEntry).toList().reversed.join('\n${'-' * 48}\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('诊断内容已复制')),
    );
  }
}

class _OverviewBand extends StatelessWidget {
  const _OverviewBand({required this.logs, required this.runtimeStatus});

  final List<DiagnosticLogEntry> logs;
  final DiagnosticRuntimeStatus? runtimeStatus;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    final recent = logs.where((entry) => entry.lastSeenAt >= cutoff).toList();
    final errors = recent.where((entry) => entry.isError).fold(
          0,
          (total, entry) => total + entry.repeatCount,
        );
    final warnings = recent.where((entry) => entry.isWarning).fold(
          0,
          (total, entry) => total + entry.repeatCount,
        );
    final modules = recent
        .where((entry) => entry.isError || entry.isWarning)
        .map((entry) => entry.category)
        .toSet()
        .length;
    final issues = _IssueSummary.fromEntries(recent);
    final attentionCount = issues.length;

    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  attentionCount == 0
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  color: attentionCount == 0 ? colors.primary : colors.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    attentionCount == 0
                        ? '当前状态：未发现需关注问题'
                        : '当前状态：存在 $attentionCount 项需关注',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('过去 24 小时', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                _Metric(label: '错误', value: errors, color: colors.error),
                _Metric(label: '警告', value: warnings, color: colors.tertiary),
                _Metric(label: '异常模块', value: modules, color: colors.primary),
              ],
            ),
            if (runtimeStatus != null) ...[
              const SizedBox(height: 16),
              _RuntimeStatusGrid(status: runtimeStatus!),
            ],
            if (issues.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('需要处理的问题', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ...issues.take(3).map(
                    (issue) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        children: [
                          Icon(
                            issue.isError
                                ? Icons.cancel_outlined
                                : Icons.warning_amber_outlined,
                            size: 18,
                            color:
                                issue.isError ? colors.error : colors.tertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              issue.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text('×${issue.count}'),
                        ],
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RuntimeStatusGrid extends StatelessWidget {
  const _RuntimeStatusGrid({required this.status});

  final DiagnosticRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final keepAliveAttention =
        status.keepAliveEnabled == true && status.keepAliveRunning != true;
    final keepAliveValue = status.keepAliveEnabled != true
        ? '未开启'
        : status.keepAliveRunning == true
            ? '运行中'
            : '需检查';
    final pushAttention = status.pushEnabled == true &&
        (status.pushConnected != true ||
            status.notificationsEnabled != true ||
            status.privateMessageChannelBlocked == true ||
            status.aliasState == 'pending_delete');
    final pushValue = status.pushEnabled != true
        ? '未开启'
        : pushAttention
            ? '需检查'
            : '正常';
    return Wrap(
      spacing: 18,
      runSpacing: 10,
      children: [
        _RuntimeState(
          label: '后台服务',
          value: keepAliveValue,
          attention: keepAliveAttention,
        ),
        _RuntimeState(
          label: '远程推送',
          value: pushValue,
          attention: pushAttention,
        ),
        _RuntimeState(
          label: '最近任务',
          value: status.hideRecentsEnabled == true ? '已隐藏' : '显示',
        ),
      ],
    );
  }
}

class _RuntimeState extends StatelessWidget {
  const _RuntimeState({
    required this.label,
    required this.value,
    this.attention = false,
  });

  final String label;
  final String value;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 142,
      child: Row(
        children: [
          Icon(
            attention ? Icons.error_outline : Icons.circle,
            size: attention ? 16 : 8,
            color: attention ? colors.error : colors.primary,
          ),
          const SizedBox(width: 7),
          Expanded(child: Text(label)),
          Text(
            value,
            style: TextStyle(
              color: attention ? colors.error : colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$value',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}

class _DiagnosticTimelineItem extends StatefulWidget {
  const _DiagnosticTimelineItem({required this.group});

  final _DiagnosticGroup group;

  @override
  State<_DiagnosticTimelineItem> createState() =>
      _DiagnosticTimelineItemState();
}

class _DiagnosticTimelineItemState extends State<_DiagnosticTimelineItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final colors = Theme.of(context).colorScheme;
    final emphasized = group.isError || group.isWarning;
    final accent = group.isError
        ? colors.error
        : group.isWarning
            ? colors.tertiary
            : colors.primary;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: emphasized ? accent.withValues(alpha: 0.06) : Colors.transparent,
        border: Border(
          left: BorderSide(color: accent, width: 2),
          bottom: BorderSide(color: colors.outlineVariant),
        ),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    DateFormat('HH:mm:ss').format(
                      DateTime.fromMillisecondsSinceEpoch(group.lastSeenAt),
                    ),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    _categoryLabel(group.category),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: accent,
                        ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                group.summary,
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (group.phaseCount > 1 || group.repeatCount > 1) ...[
                const SizedBox(height: 5),
                Text(
                  [
                    if (group.phaseCount > 1) '包含 ${group.phaseCount} 个阶段',
                    if (group.repeatCount > 1) '累计 ${group.repeatCount} 次',
                    if (group.durationMs != null) '用时 ${group.durationMs}ms',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (_expanded) ...[
                const SizedBox(height: 12),
                if (group.phaseCount > 1)
                  ...group.entries.map(
                    (entry) => _PhaseRow(entry: entry, accent: accent),
                  ),
                _StructuredDetails(entry: group.primary),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _showDetails(context, group.entries),
                      icon: const Icon(Icons.article_outlined, size: 18),
                      label: const Text('查看详情'),
                    ),
                    TextButton.icon(
                      onPressed: () => _copyIssue(context, group.entries),
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const Text('复制此问题'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PhaseRow extends StatelessWidget {
  const _PhaseRow({required this.entry, required this.accent});

  final DiagnosticLogEntry entry;
  final Color accent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Icon(Icons.circle, size: 8, color: accent),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.type,
                      style: Theme.of(context).textTheme.labelLarge),
                  Text(entry.summary,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      );
}

class _StructuredDetails extends StatelessWidget {
  const _StructuredDetails({required this.entry});

  final DiagnosticLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final values = <String>[
      if (entry.operation.isNotEmpty) '阶段：${entry.operation}',
      if (entry.httpStatus != null) 'HTTP：${entry.httpStatus}',
      if (entry.durationMs != null) '耗时：${entry.durationMs}ms',
      if (entry.retryCount > 0) '重试：${entry.retryCount} 次',
      if (entry.route.isNotEmpty) '路由：${entry.route}',
    ];
    if (values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(values.join(' · '),
          style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _DiagnosticGroup {
  const _DiagnosticGroup(this.entries);

  final List<DiagnosticLogEntry> entries;

  DiagnosticLogEntry get primary => entries.firstWhere(
        (entry) => entry.isError,
        orElse: () => entries.firstWhere(
          (entry) => entry.isWarning,
          orElse: () => entries.last,
        ),
      );
  bool get isError => entries.any((entry) => entry.isError);
  bool get isWarning => !isError && entries.any((entry) => entry.isWarning);
  int get phaseCount => entries.length;
  int get repeatCount =>
      entries.fold(0, (total, entry) => total + entry.repeatCount);
  int get lastSeenAt =>
      entries.map((entry) => entry.lastSeenAt).reduce((a, b) => a > b ? a : b);
  int? get durationMs {
    final values = entries.map((entry) => entry.durationMs).whereType<int>();
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }

  String get category => primary.category;
  String get title =>
      phaseCount > 1 && category == 'background' ? '后台服务启动' : primary.type;
  String get summary =>
      phaseCount > 1 ? '${primary.summary}，包含完整阶段记录' : primary.summary;

  static List<_DiagnosticGroup> fromEntries(
    List<DiagnosticLogEntry> entries,
  ) {
    final grouped = <String, List<DiagnosticLogEntry>>{};
    for (final entry in entries) {
      final key = entry.traceId.isEmpty ? entry.id : 'trace:${entry.traceId}';
      grouped.putIfAbsent(key, () => []).add(entry);
    }
    final groups = grouped.values.map((items) {
      items.sort((a, b) => a.firstSeenAt.compareTo(b.firstSeenAt));
      return _DiagnosticGroup(items);
    }).toList();
    groups.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return groups;
  }
}

class _IssueSummary {
  const _IssueSummary({
    required this.title,
    required this.count,
    required this.isError,
    required this.lastSeenAt,
  });

  final String title;
  final int count;
  final bool isError;
  final int lastSeenAt;

  static List<_IssueSummary> fromEntries(List<DiagnosticLogEntry> entries) {
    final groups = <String, List<DiagnosticLogEntry>>{};
    for (final entry in entries.where(
      (entry) => entry.isError || entry.isWarning,
    )) {
      final key = entry.eventCode.isNotEmpty
          ? '${entry.eventCode}|${entry.operation}|${entry.httpStatus}'
          : '${entry.category}|${entry.type}';
      groups.putIfAbsent(key, () => []).add(entry);
    }
    final issues = groups.values.map((items) {
      items.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
      return _IssueSummary(
        title: items.first.type,
        count: items.fold(0, (total, entry) => total + entry.repeatCount),
        isError: items.any((entry) => entry.isError),
        lastSeenAt: items.first.lastSeenAt,
      );
    }).toList();
    issues.sort((a, b) {
      final severity = (b.isError ? 1 : 0).compareTo(a.isError ? 1 : 0);
      return severity != 0 ? severity : b.lastSeenAt.compareTo(a.lastSeenAt);
    });
    return issues;
  }
}

String _categoryLabel(String category) => switch (category) {
      'network' => '网络',
      'auth' => '账号',
      'edu' => '教务',
      'message' => '消息',
      'storage' => '存储',
      'navigation' => '导航',
      'background' => '后台',
      'device' => '设备工具',
      _ => '应用',
    };

String _formatEntry(DiagnosticLogEntry entry) {
  final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(
    DateTime.fromMillisecondsSinceEpoch(entry.lastSeenAt),
  );
  return [
    '[$timestamp] [${entry.level.toUpperCase()}] '
        '[${_categoryLabel(entry.category)}] ${entry.type}',
    entry.summary,
    if (entry.eventCode.isNotEmpty) 'eventCode=${entry.eventCode}',
    if (entry.operation.isNotEmpty) 'operation=${entry.operation}',
    if (entry.result.isNotEmpty) 'result=${entry.result}',
    if (entry.traceId.isNotEmpty) 'traceId=${entry.traceId}',
    if (entry.httpStatus != null) 'httpStatus=${entry.httpStatus}',
    if (entry.durationMs != null) 'durationMs=${entry.durationMs}',
    if (entry.retryCount > 0) 'retryCount=${entry.retryCount}',
    if (entry.route.isNotEmpty) 'route=${entry.route}',
    if (entry.taskId != null) 'taskId=${entry.taskId}',
    'repeatCount=${entry.repeatCount}',
    if (entry.metadata.isNotEmpty) 'metadata=${jsonEncode(entry.metadata)}',
    if (entry.detail.isNotEmpty) entry.detail,
  ].join('\n');
}

void _copyIssue(BuildContext context, List<DiagnosticLogEntry> entries) {
  Clipboard.setData(
    ClipboardData(text: entries.map(_formatEntry).join('\n${'-' * 32}\n')),
  );
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('问题详情已复制')),
  );
}

Future<void> _showDetails(
  BuildContext context,
  List<DiagnosticLogEntry> entries,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.8,
        child: Column(
          children: [
            ListTile(
              title: const Text('诊断详情'),
              trailing: IconButton(
                tooltip: '复制',
                onPressed: () => _copyIssue(context, entries),
                icon: const Icon(Icons.copy_outlined),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  entries.map(_formatEntry).join('\n${'-' * 32}\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
