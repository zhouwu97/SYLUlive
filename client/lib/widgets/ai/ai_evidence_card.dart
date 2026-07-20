import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../features/ai_runtime/skills/personal_skill.dart';

class AiEvidenceCard extends StatelessWidget {
  const AiEvidenceCard({super.key, required this.evidence});

  final List<SkillEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    if (evidence.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      leading: const Icon(Icons.fact_check_outlined, size: 20),
      title: const Text('数据与计算证据', style: TextStyle(fontSize: 14)),
      children: evidence
          .map(
            (item) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(item.scope),
              subtitle: Text(
                '${item.source} · ${_time(item.fetchedAt)}'
                '${item.isStale ? ' · 已过期' : ''}',
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  static String _time(DateTime? time) => time == null
      ? '时间未知'
      : DateFormat('yyyy-MM-dd HH:mm').format(time.toLocal());
}
