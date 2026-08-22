import 'package:flutter/material.dart';

import '../../models/ai_personal_data_evidence.dart';
import '../../models/ai_source.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import 'ai_evidence_card.dart';
import 'ai_source_card.dart';

/// 回答下方的紧凑来源入口。正文不再承载来源卡片的背景和层级。
class AiSourceChips extends StatelessWidget {
  const AiSourceChips({
    super.key,
    this.sources = const <AiSource>[],
    this.evidence = const <AiPersonalDataEvidence>[],
    this.loadSourceContent,
  });

  final List<AiSource> sources;
  final List<AiPersonalDataEvidence> evidence;
  final Future<AiSourceContent> Function(int chunkId)? loadSourceContent;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty && evidence.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        children: [
          if (evidence.isNotEmpty)
            _Chip(
              icon: Icons.verified_user_outlined,
              label: '个人数据来源',
              onTap: () => _showSheet(
                context,
                AiCampusEvidenceCard(
                    evidence: evidence, initiallyExpanded: true),
              ),
            ),
          for (final source in sources)
            _Chip(
              icon: _iconFor(source.type),
              label: source.title,
              trailing: source.citationLabel,
              onTap: () => _showSheet(
                context,
                AiSourceCard(
                  source: source,
                  loadContent: loadSourceContent,
                  initiallyExpanded: true,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showSheet(BuildContext context, Widget child) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        constraints: const BoxConstraints(maxHeight: 720),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceSecondaryDark
              : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(child: child),
      ),
    );
  }

  static IconData _iconFor(AiSourceType type) => switch (type) {
        AiSourceType.schedule => Icons.calendar_month_rounded,
        AiSourceType.competitionCatalog => Icons.emoji_events_outlined,
        AiSourceType.competitionEvidence => Icons.fact_check_outlined,
        AiSourceType.policy => Icons.description_outlined,
      };
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing = '',
  });

  final IconData icon;
  final String label;
  final String trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    return Semantics(
      button: true,
      label: '查看来源：$label',
      child: SizedBox(
        height: 44,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(minHeight: 30, maxWidth: 240),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: isDark ? AppColors.surfaceSecondaryDark : Colors.white,
                border: Border.all(
                  color: isDark
                      ? AppColors.borderNormalDark
                      : AppColors.borderNormalLight,
                ),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: AppColors.brandPrimary),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: textColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (trailing.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(trailing,
                        style: const TextStyle(
                            color: AppColors.brandPrimary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700)),
                  ],
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 14, color: textColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
