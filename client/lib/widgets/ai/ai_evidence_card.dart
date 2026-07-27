import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../features/ai_runtime/skills/personal_skill.dart';
import '../../models/ai_personal_data_evidence.dart';

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

/// 校园 Agent 的个人数据证据只显示来源元数据，避免在卡片中重复展示工具结果正文。
class AiCampusEvidenceCard extends StatelessWidget {
  const AiCampusEvidenceCard({super.key, required this.evidence});

  final List<AiPersonalDataEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    if (evidence.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      leading: const Icon(Icons.verified_user_outlined, size: 20),
      title: const Text('个人数据来源', style: TextStyle(fontSize: 14)),
      children: evidence
          .map(
            (item) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                item.datasetLabel.isEmpty
                    ? item.sourceLabel
                    : '${item.datasetLabel}：${item.sourceLabel}',
              ),
              subtitle: Text(
                '更新于 ${AiEvidenceCard._time(item.fetchedAt)}'
                '${item.isStale ? ' · 已过期' : ''}',
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}
