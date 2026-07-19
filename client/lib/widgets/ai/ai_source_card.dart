import 'package:flutter/material.dart';

import '../../models/ai_source.dart';
import '../campus/campus_theme.dart';

class AiSourceCard extends StatelessWidget {
  final AiSource source;
  const AiSourceCard({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: CampusTheme.softBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ExpansionTile(
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
        subtitle: Text(source.typeLabel, style: const TextStyle(fontSize: 11)),
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
        ],
      ),
    );
  }
}
