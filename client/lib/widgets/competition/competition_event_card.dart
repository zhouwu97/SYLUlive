import 'package:flutter/material.dart';
import '../../models/competition.dart';
import 'competition_ui_tokens.dart';
import 'competition_status_helper.dart';

class CompetitionEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final VoidCallback onTap;
  final VoidCallback onAddPlan;

  const CompetitionEventCard({
    super.key,
    required this.event,
    required this.onTap,
    required this.onAddPlan,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = resolveCompetitionStatus(event, isDark);
    final criticalTime = getCompetitionCriticalTime(event);
    
    final levelAndCategory = [
      if (event.competitionLevel.isNotEmpty) event.competitionLevel,
      event.primaryCategory?.name ?? '未分类',
    ].join(' / ');

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildStatusPill(status, isDark),
                ],
              ),
              const SizedBox(height: 12),
              if (criticalTime != null)
                _buildInfoRow(Icons.access_time_rounded, criticalTime, isDark),
              const SizedBox(height: 4),
              _buildInfoRow(Icons.label_outline_rounded, levelAndCategory, isDark),
              if (event.organizer.isNotEmpty)
                ...[
                  const SizedBox(height: 4),
                  _buildInfoRow(Icons.account_balance_outlined, '主办方：${event.organizer}', isDark),
                ],
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onAddPlan,
                  style: FilledButton.styleFrom(
                    backgroundColor: CompetitionUiTokens.accent(isDark),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('加入计划', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill(CompetitionStatusView status, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: status.color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 14, color: CompetitionUiTokens.subColor(isDark)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
        ),
      ],
    );
  }
}
