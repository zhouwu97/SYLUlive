import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class MyCompetitionPlanCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final String planStatusLabel;
  final String timeStatusLabel;
  final String sourceLabel;
  final String deadlineText;
  final VoidCallback? onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onArchive;

  const MyCompetitionPlanCard({
    super.key,
    required this.item,
    required this.planStatusLabel,
    required this.timeStatusLabel,
    required this.sourceLabel,
    required this.deadlineText,
    this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userNote = '${item['user_note'] ?? ''}'.trim();
    
    // We only show one main status pill in the new design.
    // If it's archived or finished, we show that. Otherwise we show time status if it's "待通知" or similar, 
    // but the user spec says "主状态标签：例如 准备中 / 待通知". 
    // We can just show planStatus if it's not "关注中" (which we remove as per phase 8), otherwise timeStatus.
    final String mainStatus = planStatusLabel == '关注中' ? timeStatusLabel : planStatusLabel;
    
    Color statusColor;
    if (['已结束', '已归档'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.archivedColor(isDark);
    } else if (['准备中', '已报名', '已提交', '报名中'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.warningColor(isDark);
    } else if (['即将截止'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.upcomingColor(isDark);
    } else if (['待通知', '时间待确认'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.accent(isDark);
    } else {
      statusColor = CompetitionUiTokens.accent(isDark);
    }

    final card = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(top: 7),
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${item['title'] ?? '未命名比赛'}',
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
              const SizedBox(width: 8),
              _buildStatusPill(mainStatus, statusColor),
              const SizedBox(width: 8),
              _buildMoreMenu(isDark, context),
            ],
          ),
          const SizedBox(height: 12),
          _buildInfoRow(
            Icons.access_time_rounded, 
            '报名安排：${deadlineText.isEmpty ? '时间待通知' : deadlineText}', 
            isDark,
            iconColor: CompetitionUiTokens.warningColor(isDark),
          ),
          const SizedBox(height: 4),
          _buildInfoRow(
            Icons.file_download_outlined, 
            '来源：$sourceLabel', 
            isDark,
            iconColor: CompetitionUiTokens.accent(isDark).withValues(alpha: 0.72),
          ),
          if (userNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildInfoRow(Icons.note_alt_outlined, '备注：$userNote', isDark),
          ],
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
        onTap: onTap,
        child: card,
      ),
    );
  }

  Widget _buildStatusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text, bool isDark, {Color? iconColor}) {
    return Row(
      children: [
        Icon(icon, size: 14, color: iconColor ?? CompetitionUiTokens.subColor(isDark)),
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

  Widget _buildMoreMenu(bool isDark, BuildContext context) {
    final color = CompetitionUiTokens.subColor(isDark);
    final planStatus = '${item['plan_status'] ?? ''}'.trim();
    final accent = CompetitionUiTokens.accent(isDark);
    final danger = CompetitionUiTokens.dangerColor(isDark);
    final cardBg = CompetitionUiTokens.cardBg(isDark);

    return SizedBox(
      width: 28,
      height: 28,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_horiz_rounded, size: 20, color: color),
        offset: const Offset(-60, 0),
        color: cardBg,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
        ),
        onSelected: (value) {
          if (value == 'edit') onEdit();
          if (value == 'archive') onArchive();
          if (value == 'delete') onDelete();
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'edit',
            height: 48,
            child: Row(
              children: [
                Icon(Icons.edit_outlined, size: 18, color: accent),
                const SizedBox(width: 10),
                Text('编辑',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: CompetitionUiTokens.titleColor(isDark))),
              ],
            ),
          ),
          if (planStatus != 'archived')
            PopupMenuItem(
              value: 'archive',
              height: 48,
              child: Row(
                children: [
                  Icon(Icons.inventory_2_outlined, size: 18, color: accent),
                  const SizedBox(width: 10),
                  Text('归档',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: CompetitionUiTokens.titleColor(isDark))),
                ],
              ),
            ),
          PopupMenuItem(
            value: 'delete',
            height: 48,
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18, color: danger),
                const SizedBox(width: 10),
                Text('删除',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: danger)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
