import 'package:flutter/material.dart';

import '../../models/ai_capabilities.dart';
import 'campus_theme.dart';

class CampusAiEntryCard extends StatelessWidget {
  final AiCapabilities capabilities;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback? onCompetitionCompareTap;
  final VoidCallback? onAcademicAnalysisTap;
  final VoidCallback? onWeekPlanTap;

  const CampusAiEntryCard({
    super.key,
    required this.capabilities,
    required this.isDark,
    required this.onTap,
    this.onCompetitionCompareTap,
    this.onAcademicAnalysisTap,
    this.onWeekPlanTap,
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
    final actions = <Widget>[
      if (capabilities.features.hy3CompetitionCompare &&
          onCompetitionCompareTap != null)
        _AiBusinessAction(
          icon: Icons.emoji_events_outlined,
          title: '赛事对比',
          subtitle: '比较适合你的竞赛与准备重点',
          isDark: isDark,
          onTap: onCompetitionCompareTap!,
        ),
      if (capabilities.features.hy3AcademicAnalysis &&
          onAcademicAnalysisTap != null)
        _AiBusinessAction(
          icon: Icons.analytics_outlined,
          title: '学业分析',
          subtitle: '识别风险并整理改进建议',
          isDark: isDark,
          onTap: onAcademicAnalysisTap!,
        ),
      if (capabilities.features.hy3WeekPlan && onWeekPlanTap != null)
        _AiBusinessAction(
          icon: Icons.calendar_view_week_outlined,
          title: '本周计划',
          subtitle: '结合课表与目标安排一周',
          isDark: isDark,
          onTap: onWeekPlanTap!,
        ),
    ];
    return Semantics(
      container: true,
      label: '沈理 AI，$quotaDescription',
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: isDark ? CampusTheme.darkCard : CampusTheme.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : CampusTheme.border,
            ),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(20),
                  bottom:
                      actions.isEmpty ? const Radius.circular(20) : Radius.zero,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
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
                                color: isDark
                                    ? Colors.white60
                                    : CampusTheme.subText,
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
              if (actions.isNotEmpty) ...[
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : CampusTheme.border,
                ),
                for (var index = 0; index < actions.length; index++) ...[
                  actions[index],
                  if (index != actions.length - 1)
                    Divider(
                      height: 1,
                      indent: 52,
                      endIndent: 16,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : CampusTheme.border.withValues(alpha: 0.65),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AiBusinessAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _AiBusinessAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
          child: Row(
            children: [
              Icon(icon, size: 21, color: CampusTheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: isDark ? Colors.white : CampusTheme.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: isDark ? Colors.white54 : CampusTheme.subText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
