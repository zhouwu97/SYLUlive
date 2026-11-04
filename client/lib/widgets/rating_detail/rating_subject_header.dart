import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class RatingSubjectHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String initial;
  final Color? accentOverride;
  final bool showInitialBadge;

  const RatingSubjectHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.initial,
    this.accentOverride,
    this.showInitialBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = accentOverride ?? RankingTokens.teacherAccent(isDark);

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: showInitialBadge ? 16 : 20,
            fontWeight: FontWeight.w800,
            color: RankingTokens.titleColor(isDark),
          ),
        ),
        if (subtitle.trim().isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: showInitialBadge ? 12 : 13,
              color: RankingTokens.subColor(isDark),
            ),
          ),
        ],
      ],
    );

    if (!showInitialBadge) return details;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isDark
                ? accent.withValues(alpha: 0.14)
                : accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            initial.isNotEmpty ? initial[0] : '?',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: details),
      ],
    );
  }
}
