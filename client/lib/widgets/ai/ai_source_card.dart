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
        borderRadius: BorderRadius.circular(14),
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

  void _loadContent(bool expanded) {
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
      onExpansionChanged: _loadContent,
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
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [source.typeLabel, source.citationLabel]
            .where((value) => value.isNotEmpty)
            .join(' · '),
        style: const TextStyle(fontSize: 11),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            [source.publisher, source.status, source.reliabilityNote]
                .where((value) => value.isNotEmpty)
                .join(' · '),
            style: const TextStyle(
              color: CampusTheme.subText,
              fontSize: 11.5,
              height: 1.45,
            ),
          ),
        ),
        if (source.locators.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                source.locators.join(' · '),
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
