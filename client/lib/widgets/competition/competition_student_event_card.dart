import 'package:flutter/material.dart';

import '../../models/competition.dart';
import 'competition_status_helper.dart';
import 'competition_ui_tokens.dart';

class CompetitionStudentEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final VoidCallback onTap;
  final VoidCallback onAddPlan;
  final VoidCallback onJoinedTap;
  final bool joined;
  final bool isAdding;

  const CompetitionStudentEventCard({
    super.key,
    required this.event,
    required this.onTap,
    required this.onAddPlan,
    required this.onJoinedTap,
    this.joined = false,
    this.isAdding = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = resolveCompetitionStatus(event, isDark);
    final audience = _studentAudience(event);
    final reason = _studentReason(event);
    final manualLabel = competitionManualRatingShort(event.recommendationLevel);
    final schoolLabel = competitionSchoolRecognitionShort(
      status: event.schoolRecognitionStatus,
      grade: event.schoolRecognitionGrade,
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
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (schoolLabel.isNotEmpty) _softPill(schoolLabel, isDark),
                  if (event.competitionLevel.isNotEmpty)
                    _softPill(event.competitionLevel, isDark),
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
              if (audience.isNotEmpty) ...[
                const SizedBox(height: 6),
                _infoLine(Icons.groups_2_outlined, '适合：$audience', isDark),
              ],
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: CompetitionUiTokens.titleColor(isDark),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (event.fitReasons.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  event.fitReasons.join(' · '),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: CompetitionUiTokens.accent(isDark),
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
                          _outlinePill(event.participationType, isDark),
                        ...event.tags
                            .take(3)
                            .map((tag) => _outlinePill(tag, isDark)),
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
                        : Icon(joined ? Icons.check_rounded : Icons.add_rounded,
                            size: 17),
                    label: Text(isAdding
                        ? '加入中'
                        : joined
                            ? '已加入'
                            : '加入计划'),
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

  String _studentAudience(CompetitionEvent event) {
    final targetAudience = event.targetAudience.trim();
    if (targetAudience.isNotEmpty) return targetAudience;
    final summary = event.summary.trim();
    if (summary.isNotEmpty) return summary;
    return event.description.trim();
  }

  String _studentReason(CompetitionEvent event) {
    final reason = event.recommendationReason.trim();
    if (reason.isNotEmpty) return reason;
    return event.summary.trim();
  }
}

Widget _infoLine(IconData icon, String text, bool isDark) {
  return Row(
    children: [
      Icon(icon, size: 15, color: CompetitionUiTokens.subColor(isDark)),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
