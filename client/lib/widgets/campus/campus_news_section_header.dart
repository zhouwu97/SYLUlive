import 'package:flutter/material.dart';
import 'campus_theme.dart';

class CampusNewsSectionHeader extends StatelessWidget {
  final VoidCallback onCompetitionTap;
  final bool isDark;

  const CampusNewsSectionHeader({
    super.key,
    required this.onCompetitionTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '校园资讯',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : CampusTheme.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '校园通知与赛事信息',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : CampusTheme.subText,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Material(
          color: isDark
              ? CampusTheme.primary.withValues(alpha: 0.18)
              : CampusTheme.primaryLight,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onCompetitionTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: isDark ? CampusTheme.primary.withValues(alpha: 0.22) : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '竞赛中心',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: isDark ? CampusTheme.primaryLight : CampusTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: isDark ? CampusTheme.primaryLight : CampusTheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
