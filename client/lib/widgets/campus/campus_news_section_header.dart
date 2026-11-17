import '../../theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

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
                  color: AppThemeTokens.of(context).textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '校园通知与赛事信息',
                style: TextStyle(
                  fontSize: 12,
                  color: AppThemeTokens.of(context).textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Material(
          color: isDark
              ? AppThemeTokens.of(context).primary.withValues(alpha: 0.15)
              : AppThemeTokens.of(context).primaryContainer,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onCompetitionTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: isDark
                      ? AppThemeTokens.of(context)
                          .primary
                          .withValues(alpha: 0.2)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '竞赛',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppThemeTokens.of(context).tagText,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: AppThemeTokens.of(context).tagText,
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
