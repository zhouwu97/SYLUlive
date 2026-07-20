import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../skills/personal_skill.dart';
import 'tool_call_models.dart';
import 'tool_permission.dart';

class FlutterToolPermissionPrompt implements ToolPermissionPrompt {
  FlutterToolPermissionPrompt(this.context);

  final BuildContext context;

  @override
  Future<ToolPermissionDecision> request(ToolPermissionPreview preview) async {
    final result = await showDialog<ToolPermissionDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ToolPermissionDialog(preview: preview),
    );
    return result ?? ToolPermissionDecision.denied;
  }
}

class ToolPermissionDialog extends StatefulWidget {
  const ToolPermissionDialog({super.key, required this.preview});

  final ToolPermissionPreview preview;

  @override
  State<ToolPermissionDialog> createState() => _ToolPermissionDialogState();
}

class _ToolPermissionDialogState extends State<ToolPermissionDialog> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final canGrantSession = preview.sensitivity == SkillSensitivity.low;
    return AlertDialog(
      title: const Text('个人数据授权'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('数据将发送到：${preview.destination}'),
              const SizedBox(height: 16),
              const Text('本次将读取'),
              const SizedBox(height: 6),
              ...preview.dataItems.map(_dataItem),
              TextButton.icon(
                onPressed: () => setState(() => _showDetails = !_showDetails),
                icon: Icon(
                  _showDetails ? Icons.expand_less : Icons.expand_more,
                ),
                label: Text(_showDetails ? '收起详细字段' : '查看详细字段'),
              ),
              if (_showDetails) ...[
                ...preview.outputFields.map(
                  (item) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check, size: 18),
                    title: Text(item),
                  ),
                ),
                const Text('不会读取'),
                ...preview.excludedDataLabels.map(
                  (item) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.close, size: 18),
                    title: Text(item),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            ToolPermissionDecision.denied,
          ),
          child: const Text('取消'),
        ),
        if (canGrantSession)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              ToolPermissionDecision.allowSession,
            ),
            child: const Text('本次会话允许'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            ToolPermissionDecision.allowOnce,
          ),
          child: const Text('允许本次'),
        ),
      ],
    );
  }

  Widget _dataItem(ToolDataPreviewItem item) {
    final fetchedAt = item.fetchedAt;
    final time = fetchedAt == null
        ? '同步时间将在读取后核验'
        : DateFormat('yyyy-MM-dd HH:mm').format(fetchedAt.toLocal());
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.shield_outlined, size: 20),
      title: Text(item.label),
      subtitle: Text(item.isStale ? '$time · 数据已过期' : time),
    );
  }
}
