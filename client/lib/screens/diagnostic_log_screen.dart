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
  List<DiagnosticLogEntry> _logs = [];
  bool _isLoading = true;
  String _filter = 'all'; // all, warning, error

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }

    try {
      final logs = await DiagnosticLogService.instance.getLogs();
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _logs = [];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('日志读取失败: $e\n点击重试')));
    }
  }

  Future<void> _clearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定要清空所有诊断日志吗？此操作无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await DiagnosticLogService.instance.clearLogs();
        if (!mounted) return;
        await _loadLogs();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('日志清理失败: $e')));
      }
    }
  }

  void _copyAll() {
    if (_logs.isEmpty) return;

    // 正序输出，便于从前往后分析
    final sortedLogs = List<DiagnosticLogEntry>.from(_logs)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final sb = StringBuffer();
    for (var log in sortedLogs) {
      final timeStr = DateFormat(
        'yyyy-MM-dd HH:mm:ss',
      ).format(DateTime.fromMillisecondsSinceEpoch(log.timestamp));
      sb.writeln(
        '[$timeStr] [${log.level.toUpperCase()}] [${log.source}] ${log.type}',
      );
      sb.writeln('Summary: ${log.summary}');
      sb.writeln(
        'App: ${log.appVersion} | '
        'Device: ${log.manufacturer} ${log.model} | '
        'SDK: ${log.sdkInt}',
      );
      sb.writeln(
        'Session: ${log.sessionId} | PID: ${log.pid} | '
        'Elapsed: ${log.elapsedRealtime}',
      );
      final formatTime = (int ms) => DateFormat(
        'MM-dd HH:mm:ss',
      ).format(DateTime.fromMillisecondsSinceEpoch(ms));
      sb.writeln(
        'FirstSeen: ${formatTime(log.firstSeenAt)} | '
        'LastSeen: ${formatTime(log.lastSeenAt)} | '
        'Repeat: ${log.repeatCount}',
      );
      if (log.detail.isNotEmpty) {
        sb.writeln('Detail: \n${log.detail}');
      }
      sb.writeln('-' * 40);
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制全部日志到剪贴板')));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final filteredLogs = _logs.where((log) {
      if (_filter == 'warning') return log.isWarning || log.isError;
      if (_filter == 'error') return log.isError;
      return true;
    }).toList();

    String timeRange = '';
    if (_logs.isNotEmpty) {
      final earliest = DateTime.fromMillisecondsSinceEpoch(
        _logs.last.timestamp,
      );
      final latest = DateTime.fromMillisecondsSinceEpoch(_logs.first.timestamp);
      final fmt = DateFormat('MM-dd HH:mm');
      timeRange = '最早 ${fmt.format(earliest)} · 最近 ${fmt.format(latest)}';
    }

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF111318)
          : const Color(0xFFF5F6F8),
      appBar: AppBar(
        title: const Text('诊断日志'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: '复制全部',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空日志',
            onPressed: _clearLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '共 ${_logs.length} 条${timeRange.isNotEmpty ? ' · $timeRange' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Row(
              children: [
                _buildFilterChip('全部', 'all'),
                const SizedBox(width: 8),
                _buildFilterChip('警告', 'warning'),
                const SizedBox(width: 8),
                _buildFilterChip('错误', 'error'),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filteredLogs.isEmpty
                ? const Center(child: Text('暂无日志记录'))
                : ListView.builder(
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      return _LogEntryCard(entry: filteredLogs[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _filter == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _filter = value);
        }
      },
    );
  }
}

class _LogEntryCard extends StatefulWidget {
  final DiagnosticLogEntry entry;

  const _LogEntryCard({required this.entry});

  @override
  State<_LogEntryCard> createState() => _LogEntryCardState();
}

class _LogEntryCardState extends State<_LogEntryCard> {
  bool _expanded = false;

  Color _getLevelColor() {
    if (widget.entry.isError) return Colors.red;
    if (widget.entry.isWarning) return Colors.orange;
    return Colors.blue;
  }

  String _getLevelText() {
    if (widget.entry.isError) return '🔴 错误';
    if (widget.entry.isWarning) return '🟠 警告';
    return '🔵 信息';
  }

  void _copyDetail() {
    final log = widget.entry;
    final timeStr = DateFormat(
      'yyyy-MM-dd HH:mm:ss',
    ).format(DateTime.fromMillisecondsSinceEpoch(log.timestamp));
    final sb = StringBuffer();
    sb.writeln(
      '[$timeStr] [${log.level.toUpperCase()}] [${log.source}] ${log.type}',
    );
    sb.writeln('Summary: ${log.summary}');
    sb.writeln(
      'App: ${log.appVersion} | '
      'Device: ${log.manufacturer} ${log.model} | '
      'SDK: ${log.sdkInt}',
    );
    sb.writeln(
      'Session: ${log.sessionId} | PID: ${log.pid} | '
      'Elapsed: ${log.elapsedRealtime}',
    );
    final formatTime = (int ms) => DateFormat(
      'MM-dd HH:mm:ss',
    ).format(DateTime.fromMillisecondsSinceEpoch(ms));
    sb.writeln(
      'FirstSeen: ${formatTime(log.firstSeenAt)} | '
      'LastSeen: ${formatTime(log.lastSeenAt)} | '
      'Repeat: ${log.repeatCount}',
    );
    if (log.detail.isNotEmpty) {
      sb.writeln('Detail: \n${log.detail}');
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制日志详情')));
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final timeFormat = DateFormat('HH:mm:ss');
    final timeStr = timeFormat.format(
      DateTime.fromMillisecondsSinceEpoch(entry.timestamp),
    );

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E2025) : Colors.white;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      color: cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    _getLevelText(),
                    style: TextStyle(
                      color: _getLevelColor(),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white12 : Colors.black12,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      entry.source,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.type,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    timeStr,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (!_expanded) ...[
                Text(
                  entry.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                if (entry.repeatCount > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      '重复 ${entry.repeatCount} 次',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.orange,
                      ),
                    ),
                  ),
              ] else ...[
                Text(
                  entry.summary,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black26
                        : Colors.black.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        'SessionId: ${entry.sessionId} | PID: ${entry.pid}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Colors.grey,
                        ),
                      ),
                      if (entry.repeatCount > 1)
                        SelectableText(
                          '重复: ${entry.repeatCount} 次\n首次: ${DateFormat('MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(entry.firstSeenAt))}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: Colors.orange,
                          ),
                        ),
                      const SizedBox(height: 4),
                      SelectableText(
                        entry.detail.isEmpty ? '无详细信息' : entry.detail,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _copyDetail,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制详情'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
