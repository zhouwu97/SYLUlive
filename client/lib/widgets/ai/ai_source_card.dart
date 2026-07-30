import 'package:flutter/material.dart';

import '../../models/ai_source.dart';
import '../campus/campus_theme.dart';

class AiSourceCard extends StatelessWidget {
  final AiSource source;
  final Future<AiSourceContent> Function(int chunkId)? loadContent;
  const AiSourceCard({super.key, required this.source, this.loadContent});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: CampusTheme.softBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _SourceExpansionTile(source: source, loadContent: loadContent),
    );
  }
}

class _SourceExpansionTile extends StatefulWidget {
  final AiSource source;
  final Future<AiSourceContent> Function(int chunkId)? loadContent;
  const _SourceExpansionTile({required this.source, this.loadContent});

  @override
  State<_SourceExpansionTile> createState() => _SourceExpansionTileState();
}

class _SourceExpansionTileState extends State<_SourceExpansionTile> {
  Future<AiSourceContent>? _contentRequest;
  bool _expanded = false;

  void _handleExpansionChanged(bool expanded) {
    setState(() => _expanded = expanded);
    if (!expanded ||
        _contentRequest != null ||
        widget.loadContent == null ||
        widget.source.type != AiSourceType.policy ||
        widget.source.chunkId <= 0) {
      return;
    }
    setState(() {
      _contentRequest = widget.loadContent!(widget.source.chunkId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return ExpansionTile(
      onExpansionChanged: _handleExpansionChanged,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(
        switch (source.type) {
          AiSourceType.schedule => Icons.calendar_month_rounded,
          AiSourceType.competitionCatalog => Icons.emoji_events_outlined,
          AiSourceType.competitionEvidence => Icons.fact_check_outlined,
          AiSourceType.policy => Icons.description_rounded,
        },
        color: CampusTheme.primary,
        size: 20,
      ),
      title: Text(
        source.title,
        maxLines: _expanded ? null : 2,
        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          source.typeLabel,
          source.citationLabel,
        ].where((value) => value.isNotEmpty).join(' · '),
        style: const TextStyle(fontSize: 11),
      ),
      children: [
        if (source.type == AiSourceType.competitionCatalog ||
            source.type == AiSourceType.competitionEvidence) ...[
          _SourceMetadataRow(
            icon: Icons.dataset_outlined,
            label: '目录版本',
            value: source.datasetVersion.isEmpty
                ? '未标注'
                : source.datasetVersion,
          ),
          _SourceMetadataRow(
            icon: Icons.tag_rounded,
            label: '赛事编号',
            value: source.competitionId.isEmpty ? '未标注' : source.competitionId,
          ),
          _SourceMetadataRow(
            icon: Icons.school_outlined,
            label: '学校认定',
            value: source.schoolRecognition.isEmpty
                ? '待确认'
                : source.schoolRecognition,
          ),
          _SourceMetadataRow(
            icon: Icons.assessment_outlined,
            label: '赛事价值',
            value: source.competitionRating.isEmpty
                ? '未评级'
                : source.competitionRating,
          ),
          _SourceMetadataRow(
            icon: Icons.fact_check_outlined,
            label: '证据等级',
            value: source.evidenceSubgrade.isEmpty
                ? '待确认'
                : source.evidenceSubgrade,
          ),
          _SourceMetadataRow(
            icon: Icons.auto_awesome_outlined,
            label: 'AI 模式',
            value: source.aiMode == 'candidate_explanation' ? '候选解释' : '未启用',
          ),
          _SourceMetadataRow(
            icon: Icons.update_rounded,
            label: '最后更新',
            value: _sourceDate(source.lastUpdated),
          ),
        ] else ...[
          _SourceMetadataRow(
            icon: Icons.apartment_rounded,
            label: '发布部门',
            value: source.departmentLabel,
          ),
          _SourceMetadataRow(
            icon: Icons.verified_outlined,
            label: '文档状态',
            value: source.statusLabel,
          ),
          _SourceMetadataRow(
            icon: Icons.event_available_outlined,
            label: '生效时间',
            value: source.effectiveLabel,
          ),
          _SourceMetadataRow(
            icon: Icons.location_on_outlined,
            label: '条款位置',
            value: source.locatorLabel,
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              source.reliabilityNote,
              style: const TextStyle(
                color: CampusTheme.subText,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
          ),
        ),
        if (_contentRequest != null)
          FutureBuilder<AiSourceContent>(
            future: _contentRequest,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              if (snapshot.hasError) {
                return const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    '正文加载失败，请稍后重试',
                    style: TextStyle(color: CampusTheme.subText, fontSize: 12),
                  ),
                );
              }
              final content = snapshot.data;
              if (content == null || content.content.trim().isEmpty) {
                return const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    '暂无可展开的正文',
                    style: TextStyle(color: CampusTheme.subText, fontSize: 12),
                  ),
                );
              }
              return Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F8F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  content.content,
                  style: const TextStyle(fontSize: 12.5, height: 1.55),
                ),
              );
            },
          ),
      ],
    );
  }
}

String _sourceDate(DateTime? value) {
  if (value == null) return '未标注';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _SourceMetadataRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SourceMetadataRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: CampusTheme.subText),
          const SizedBox(width: 6),
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: const TextStyle(
                color: CampusTheme.subText,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
