import 'package:flutter/material.dart';

import '../../models/competition.dart';
import 'competition_status_helper.dart';
import 'competition_ui_tokens.dart';

class CompetitionStudentEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final VoidCallback onTap;
  final VoidCallback onAddPlan;
  final VoidCallback onJoinedTap;
  final VoidCallback? onWhyTap;
  final bool joined;
  final bool isAdding;
  final bool showRecommendations;

  const CompetitionStudentEventCard({
    super.key,
    required this.event,
    required this.onTap,
    required this.onAddPlan,
    required this.onJoinedTap,
    this.onWhyTap,
    this.joined = false,
    this.isAdding = false,
    this.showRecommendations = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = resolveCompetitionStatus(event, isDark);
    final candidateMode = event.coreReason.trim().isNotEmpty;
    final reason =
        candidateMode ? event.coreReason.trim() : event.summary.trim();
    final manualLabel = competitionManualRatingShort(event.competitionRating);
    final schoolLabel = competitionSchoolRecognitionShort(
      status: event.schoolRecognitionStatus,
      grade: event.schoolRecognitionGrade,
    );
    // 匹配度只出现在候选链路（目录列表不带 match_tier），
    // 徽标同时带图标与文字，不依赖颜色单独表达档位（ACCESSIBILITY §Dark）。
    final matchTierLabel = competitionMatchTierLabel(event.matchTier);
    final matchBasisSummary = competitionMatchBasisSummary(
      basis: event.matchBasis,
      clusters: event.matchedClusters,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      event.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.24,
                        fontWeight: FontWeight.w900,
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                  ),
                  if (manualLabel.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    _solidPill(
                      manualLabel,
                      CompetitionUiTokens.accent(isDark),
                      isDark,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              if (matchTierLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _matchPill(matchTierLabel, event.matchTier, isDark),
                      if (matchBasisSummary.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            matchBasisSummary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: CompetitionUiTokens.subColor(isDark),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (schoolLabel.isNotEmpty) _softPill(schoolLabel, isDark),
                  if (event.competitionLevel.isNotEmpty)
                    _softPill(competitionLevelLabel(event.competitionLevel), isDark),
                  if (event.primaryCategory != null)
                    _softPill(event.primaryCategory!.name, isDark),
                ],
              ),
              const SizedBox(height: 10),
              _infoLine(
                Icons.schedule_rounded,
                _studentTimeText(event, status.label),
                isDark,
              ),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (candidateMode) ...[
                      Icon(
                        Icons.rule_rounded,
                        size: 16,
                        color: CompetitionUiTokens.accent(isDark),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        reason,
                        maxLines: candidateMode ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: CompetitionUiTokens.titleColor(isDark),
                          fontWeight:
                              candidateMode ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (candidateMode && onWhyTap != null)
                      TextButton(
                        onPressed: onWhyTap,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.only(left: 8),
                          minimumSize: const Size(0, 28),
                        ),
                        child: const Text('为什么'),
                      ),
                  ],
                ),
              ],
              if (candidateMode && event.cautions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  event.cautions.take(2).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: CompetitionUiTokens.warningColor(isDark),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (candidateMode && event.hasPendingInformation) ...[
                const SizedBox(height: 8),
                Text(
                  '信息待确认',
                  style: TextStyle(
                    fontSize: 12,
                    color: CompetitionUiTokens.warningColor(isDark),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (event.participationType.isNotEmpty)
                          _outlinePill(
                            competitionParticipationLabel(event.participationType),
                            isDark,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: isAdding
                        ? null
                        : joined
                            ? onJoinedTap
                            : onAddPlan,
                    icon: isAdding
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            joined ? Icons.check_rounded : Icons.add_rounded,
                            size: 17,
                          ),
                    label: Text(
                      isAdding
                          ? '加入中'
                          : joined
                              ? '已加入'
                              : '加入计划',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: CompetitionUiTokens.accent(isDark),
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _infoLine(IconData icon, String text, bool isDark) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 15, color: CompetitionUiTokens.subColor(isDark)),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.2,
            color: CompetitionUiTokens.subColor(isDark),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

Widget _solidPill(String label, Color color, bool isDark) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: CompetitionUiTokens.cardBg(isDark),
        fontSize: 12,
        height: 1,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

/// 匹配度徽标：浅底 + 语义色文字 + 图标。
/// 图标是必需的——「高度匹配 / 可以探索」不能只靠颜色区分（ACCESSIBILITY §Dark）。
Widget _matchPill(String label, String tier, bool isDark) {
  final color = CompetitionUiTokens.matchTierColor(tier, isDark);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: CompetitionUiTokens.matchTierSoft(tier, isDark),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.auto_awesome_rounded, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}

Widget _softPill(String label, bool isDark) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: CompetitionUiTokens.accentSoft(isDark),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: CompetitionUiTokens.accent(isDark),
        fontSize: 11,
        height: 1,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

Widget _outlinePill(String label, bool isDark) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: CompetitionUiTokens.subColor(isDark),
        fontSize: 11,
        height: 1,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

String _studentTimeText(CompetitionEvent event, String statusLabel) {
  final critical = getCompetitionCriticalTime(event);
  if (critical != null) return critical;
  return '报名：$statusLabel';
}
