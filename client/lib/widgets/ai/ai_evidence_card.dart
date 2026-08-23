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
  const AiCampusEvidenceCard({
    super.key,
    required this.evidence,
    this.initiallyExpanded = false,
  });

  final List<AiPersonalDataEvidence> evidence;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final grouped = groupAiPersonalDataEvidence(evidence);
    if (grouped.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      leading: const Icon(Icons.verified_user_outlined, size: 20),
      title: const Text('个人数据来源', style: TextStyle(fontSize: 14)),
      children: grouped
          .map(
            (item) => _PersonalEvidenceDetails(item: item),
          )
          .toList(growable: false),
    );
  }
}

class _PersonalEvidenceDetails extends StatelessWidget {
  const _PersonalEvidenceDetails({required this.item});

  final AiPersonalDataEvidence item;

  @override
  Widget build(BuildContext context) {
    final courses = item.academicCourses;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              item.datasetLabel.isEmpty
                  ? item.sourceLabel
                  : '${item.datasetLabel}：${item.sourceLabel}',
            ),
            subtitle: Text(
              item.fetchedAt == null
                  ? (item.isStale ? '数据时间未知 · 已过期' : '数据时间未知')
                  : '更新于 ${AiEvidenceCard._time(item.fetchedAt)}'
                      '${item.isStale ? ' · 已过期' : ''}',
            ),
          ),
          if (item.academicCreditSummary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                item.academicCreditSummary,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final course in courses)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(course.name)),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      course.detail,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
