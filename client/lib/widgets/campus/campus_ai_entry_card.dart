import 'package:flutter/material.dart';

import '../../models/ai_capabilities.dart';
import 'campus_theme.dart';

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
    final foreground = isDark ? Colors.white : CampusTheme.text;
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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : CampusTheme.border,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? CampusTheme.primary.withValues(alpha: 0.20)
                        : CampusTheme.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: CampusTheme.primary,
                    size: 23,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '校园 Agent',
                        style: TextStyle(
                          color: foreground,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '帮你查信息、看安排、做计划',
                        style: TextStyle(
                          color: isDark ? Colors.white60 : CampusTheme.subText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  quotaBadge,
                  style: const TextStyle(
                    color: CampusTheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  Icons.chevron_right_rounded,
                  color: isDark ? Colors.white38 : Colors.black38,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
