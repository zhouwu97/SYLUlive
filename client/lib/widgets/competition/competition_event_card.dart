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
      margin: const EdgeInsets.only(bottom: 10),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                        height: 1.22,
                        fontWeight: FontWeight.w800,
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (event.status == 'draft') ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: CompetitionUiTokens.subColor(isDark).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '草稿',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.0,
                          fontWeight: FontWeight.w700,
                          color: CompetitionUiTokens.subColor(isDark),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  _buildStatusPill(status, isDark),
                ],
              ),
              const SizedBox(height: 8),
              if (criticalTime != null) ...[
                _buildInfoRow(Icons.access_time_rounded, criticalTime, isDark),
                const SizedBox(height: 4),
              ],
              if (event.organizer.isNotEmpty) ...[
                _buildInfoRow(Icons.account_balance_outlined, '主办方：${event.organizer}', isDark),
                const SizedBox(height: 4),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _buildInfoRow(Icons.label_outline_rounded, levelAndCategory, isDark),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 34,
                    child: FilledButton.icon(
                      onPressed: onAddPlan,
                      style: FilledButton.styleFrom(
                        backgroundColor: CompetitionUiTokens.accent(isDark),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('加入计划', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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

  Widget _buildStatusPill(CompetitionStatusView status, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: status.color,
          fontSize: 11,
          height: 1.0,
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
              height: 1.15,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
        ),
      ],
    );
  }
}
