import '../../theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

import '../../models/ai_capabilities.dart';
import '../app_card.dart';

/// 校园页的校园 Agent 主入口，业务快捷问题统一放在 AI 页内维护。
class CampusAiEntryCard extends StatelessWidget {
  final AiCapabilities capabilities;
  final bool isDark;
  final VoidCallback onTap;

  const CampusAiEntryCard({
    super.key,
    required this.capabilities,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = AppThemeTokens.of(context).textPrimary;
    final quotaDescription = capabilities.quota.unlimited
        ? '使用次数不限'
        : '每小时 ${capabilities.quota.limit} 次';
    final quotaBadge = capabilities.quota.unlimited
        ? '不限次数'
        : '剩余 ${capabilities.quota.remaining} 次';

    return Semantics(
      container: true,
      button: true,
      label: '校园 Agent，$quotaDescription',
      child: AppCardSurface(
        constraints: const BoxConstraints(minHeight: 72),
        decoration: BoxDecoration(
            color: AppThemeTokens.of(context).card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppThemeTokens.of(context).cardBorder)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: isDark
                            ? AppThemeTokens.of(context)
                                .primary
                                .withValues(alpha: 0.20)
                            : AppThemeTokens.of(context).primaryContainer,
                        borderRadius: BorderRadius.circular(12)),
                    child: Icon(Icons.auto_awesome_rounded,
                        color: AppThemeTokens.of(context).primary, size: 23)),
                const SizedBox(width: 11),
                Expanded(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('校园 Agent',
                          style: TextStyle(
                              color: foreground,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('帮你查信息、看安排、做计划',
                          style: TextStyle(
                              color: AppThemeTokens.of(context).textSecondary,
                              fontSize: 12))
                    ])),
                Text(quotaBadge,
                    style: TextStyle(
                        color: AppThemeTokens.of(context).primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 5),
                Icon(Icons.chevron_right_rounded,
                    color: AppThemeTokens.of(context).textTertiary, size: 20)
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
