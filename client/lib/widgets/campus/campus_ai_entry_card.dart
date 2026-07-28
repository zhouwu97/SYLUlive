import 'package:flutter/material.dart';

import '../../models/ai_capabilities.dart';
import 'campus_theme.dart';

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
      button: true,
      label: '打开沈理 AI，$quotaDescription',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(20),
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
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: CampusTheme.primary,
                    size: 23,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '沈理 AI',
                        style: TextStyle(
                          color: foreground,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '校园政策与课表助手',
                        style: TextStyle(
                          color: isDark ? Colors.white60 : CampusTheme.subText,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$quotaDescription · 每次最多 ${capabilities.maxMessageChars} 字',
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black45,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      quotaBadge,
                      style: const TextStyle(
                        color: CampusTheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: isDark ? Colors.white38 : Colors.black38,
                      size: 20,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
