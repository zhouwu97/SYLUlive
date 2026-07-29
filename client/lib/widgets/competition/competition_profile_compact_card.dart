import 'package:flutter/material.dart';

import '../../models/competition_dashboard_summary.dart';
import '../../models/competition_preference.dart';
import 'competition_ui_tokens.dart';

class CompetitionProfileCompactCard extends StatelessWidget {
  final bool isLoggedIn;
  final CompetitionDashboardSummary? summary;
  final bool loading;
  final String? error;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  const CompetitionProfileCompactCard({
    super.key,
    required this.isLoggedIn,
    required this.summary,
    required this.loading,
    required this.error,
    required this.onTap,
    required this.onRetry,
  });

  String get _subtitle {
    if (!isLoggedIn) return '登录后管理竞赛目标、经历与能力画像';
    if (error != null && summary == null) return '竞赛档案暂时无法读取';
    if (loading && summary == null) return '正在读取竞赛档案';
    final data = summary;
    if (data == null ||
        (!data.preferenceConfigured && data.awardTotal == 0)) {
      return '还未完善 · 设置目标或添加竞赛经历';
    }
    if (data.pendingAwardCount > 0) {
      return '${data.awardTotal}段经历 · ${data.pendingAwardCount}项核验中 · 查看竞赛画像';
    }
    if (data.awardTotal > 0) {
      return '目标${data.preferenceConfigured ? '已设置' : '待完善'} · '
          '${data.awardTotal}段经历 · ${data.verifiedAwardCount}项已核验';
    }
    final goal = competitionGoalLabels[data.primaryGoal] ?? data.primaryGoal;
    final parts = <String>[
      if (goal.isNotEmpty) goal,
      if (data.primaryDirection.isNotEmpty) data.primaryDirection,
      '暂无竞赛经历',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final failed = error != null && summary == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        height: 68,
        child: Material(
          color: CompetitionUiTokens.cardBg(isDark),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              CompetitionUiTokens.compactCardRadius,
            ),
            side: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
          ),
          child: InkWell(
            key: const Key('competition-profile-compact-card'),
            onTap: failed ? onRetry : onTap,
            borderRadius: BorderRadius.circular(
              CompetitionUiTokens.compactCardRadius,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.diamond_outlined,
                    size: 22,
                    color: CompetitionUiTokens.accent(isDark),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '我的竞赛档案',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: CompetitionUiTokens.titleColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: CompetitionUiTokens.subColor(isDark),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (failed)
                    IconButton(
                      key: const Key('competition-profile-retry'),
                      tooltip: '重试',
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                      color: CompetitionUiTokens.accent(isDark),
                    )
                  else ...[
                    Text(
                      '查看',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: CompetitionUiTokens.accent(isDark),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: CompetitionUiTokens.accent(isDark),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
