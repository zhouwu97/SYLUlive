import 'package:flutter/material.dart';

import '../../features/ai_runtime/deterministic/graduation_requirement_engine.dart';

class GraduationChecklistScreen extends StatelessWidget {
  const GraduationChecklistScreen({
    super.key,
    required this.readiness,
  });

  final GraduationReadiness readiness;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('毕业清单')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.policy_outlined),
            title: const Text('适用规则'),
            subtitle: Text(readiness.policyId),
          ),
          const Divider(),
          ...readiness.items.map(
            (item) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_icon(item.state), color: _color(item.state)),
              title: Text(item.label),
              subtitle: Text(item.summary),
              trailing: Text(_label(item.state)),
            ),
          ),
          if (readiness.warnings.isNotEmpty) ...[
            const Divider(),
            ...readiness.warnings.map(
              (warning) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline),
                title: Text(warning),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _icon(RequirementState state) => switch (state) {
        RequirementState.completed => Icons.check_circle_outline,
        RequirementState.notCompleted => Icons.pending_outlined,
        RequirementState.unknown => Icons.help_outline,
        RequirementState.blocked => Icons.block_outlined,
        RequirementState.notApplicable => Icons.remove_circle_outline,
      };

  Color _color(RequirementState state) => switch (state) {
        RequirementState.completed => Colors.green,
        RequirementState.notCompleted => Colors.orange,
        RequirementState.unknown => Colors.blueGrey,
        RequirementState.blocked => Colors.red,
        RequirementState.notApplicable => Colors.grey,
      };

  String _label(RequirementState state) => switch (state) {
        RequirementState.completed => '已完�?,
        RequirementState.notCompleted => '未完�?,
        RequirementState.unknown => '未知',
        RequirementState.blocked => '阻断',
        RequirementState.notApplicable => '不适用',
      };
}
