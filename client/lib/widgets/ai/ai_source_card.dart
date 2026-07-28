import 'package:flutter/material.dart';

import '../../models/ai_source.dart';
import '../campus/campus_theme.dart';

class AiSourceCard extends StatelessWidget {
  final AiSource source;
  final Future<AiSourceContent> Function(int chunkId)? loadContent;
  const AiSourceCard({
    super.key,
    required this.source,
    this.loadContent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: CampusTheme.softBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _SourceExpansionTile(
        source: source,
        loadContent: loadContent,
      ),
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
        source.type == AiSourceType.schedule
            ? Icons.calendar_month_rounded
            : Icons.description_rounded,
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
        [source.typeLabel, source.citationLabel]
            .where((value) => value.isNotEmpty)
            .join(' · '),
        style: const TextStyle(fontSize: 11),
      ),
      children: [
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
                  child: Text('正文加载失败，请稍后重试',
                      style:
                          TextStyle(color: CampusTheme.subText, fontSize: 12)),
                );
              }
              final content = snapshot.data;
              if (content == null || content.content.trim().isEmpty) {
                return const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('暂无可展开的正文',
                      style:
                          TextStyle(color: CampusTheme.subText, fontSize: 12)),
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
                child: Text(content.content,
                    style: const TextStyle(fontSize: 12.5, height: 1.55)),
              );
            },
          ),
      ],
    );
  }
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
