import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class MyCompetitionPlanCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final String planStatusLabel;
  final String timeStatusLabel;
  final String sourceLabel;
  final String deadlineText;
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
    
    // Determine color based on mainStatus roughly
    Color statusColor = CompetitionUiTokens.pendingColor(isDark);
    if (['已结束', '已归档'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.archivedColor(isDark);
    } else if (['准备中', '已报名', '已提交'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.warningColor(isDark);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
          _buildInfoRow(Icons.access_time_rounded, '报名安排：${deadlineText.isEmpty ? '时间待通知' : deadlineText}', isDark),
          const SizedBox(height: 4),
          _buildInfoRow(Icons.file_download_outlined, '来源：$sourceLabel', isDark),
          if (userNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildInfoRow(Icons.note_alt_outlined, '备注：$userNote', isDark),
          ],
        ],
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

  Widget _buildMoreMenu(bool isDark, BuildContext context) {
    final color = CompetitionUiTokens.subColor(isDark);
    final planStatus = '${item['plan_status'] ?? ''}'.trim();
    
    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_horiz_rounded, size: 20, color: color),
        offset: const Offset(0, 30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onSelected: (value) {
          if (value == 'edit') onEdit();
          if (value == 'archive') onArchive();
          if (value == 'delete') onDelete();
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit_outlined, size: 18),
                SizedBox(width: 8),
                Text('编辑'),
              ],
            ),
          ),
          if (planStatus != 'archived')
            const PopupMenuItem(
              value: 'archive',
              child: Row(
                children: [
                  Icon(Icons.archive_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('归档'),
                ],
              ),
            ),
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                SizedBox(width: 8),
                Text('删除', style: TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
