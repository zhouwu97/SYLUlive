import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';
import '../app_action_popup_menu.dart';
import 'competition_status_helper.dart';

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
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onSelect;

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
    this.selectionMode = false,
    this.isSelected = false,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userNote = '${item['user_note'] ?? ''}'.trim();

    // 卡片只展示一个主状态：非“关注中”时优先展示计划状态，否则展示时间状态。
    final String mainStatus =
        planStatusLabel == '关注中' ? timeStatusLabel : planStatusLabel;

    Color statusColor;
    if (['已结束', '已归档'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.archivedColor(isDark);
    } else if (['准备中', '已报名', '已提交', '报名中'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.warningColor(isDark);
    } else if (['即将截止'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.upcomingColor(isDark);
    } else if (['待通知', '时间待公布', '时间待确认'].contains(mainStatus)) {
      statusColor = CompetitionUiTokens.accent(isDark);
    } else {
      statusColor = CompetitionUiTokens.accent(isDark);
    }

    final manualLabel =
        competitionManualRatingShort('${item['recommendation_level'] ?? ''}');
    final schoolLabel = competitionSchoolRecognitionShort(
      status: '${item['school_recognition_status'] ?? ''}',
      grade: '${item['school_recognition_grade'] ?? ''}',
    );

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
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 12, top: 4),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => onSelect?.call(),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
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
              if (!selectionMode) ...[
                const SizedBox(width: 8),
                _buildMoreMenu(isDark, context),
              ],
            ],
          ),
          if (manualLabel.isNotEmpty || schoolLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (manualLabel.isNotEmpty)
                  Text(
                    manualLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: CompetitionUiTokens.accent(isDark),
                    ),
                  ),
                if (manualLabel.isNotEmpty && schoolLabel.isNotEmpty)
                  Text(
                    ' · ',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: CompetitionUiTokens.subColor(isDark),
                    ),
                  ),
                if (schoolLabel.isNotEmpty)
                  Text(
                    schoolLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: CompetitionUiTokens.accent(isDark),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _buildInfoRow(
            Icons.access_time_rounded,
            '报名安排：${deadlineText.isEmpty ? '时间待公布' : deadlineText}',
            isDark,
            iconColor: CompetitionUiTokens.warningColor(isDark),
          ),
          const SizedBox(height: 4),
          _buildInfoRow(
            Icons.file_download_outlined,
            '来源：$sourceLabel',
            isDark,
            iconColor:
                CompetitionUiTokens.accent(isDark).withValues(alpha: 0.72),
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

  Widget _buildInfoRow(IconData icon, String text, bool isDark,
      {Color? iconColor}) {
    return Row(
      children: [
        Icon(icon,
            size: 14, color: iconColor ?? CompetitionUiTokens.subColor(isDark)),
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
    final entries = <Object>[
      const AppPopupAction(
        value: 'edit',
        label: '编辑',
        icon: Icons.edit_outlined,
      ),
      if (planStatus != 'archived')
        const AppPopupAction(
          value: 'archive',
          label: '归档',
          icon: Icons.inventory_2_outlined,
        ),
      const AppPopupAction(
        value: 'delete',
        label: '删除',
        icon: Icons.delete_outline_rounded,
        danger: true,
      ),
    ];

    return SizedBox(
      width: 32,
      height: 32,
      child: AppActionPopupMenu(
        width: 122,
        offset: const Offset(0, 6),
        accentColor: CompetitionUiTokens.accent(isDark),
        dangerColor: CompetitionUiTokens.dangerColor(isDark),
        icon: Icon(Icons.more_horiz_rounded, size: 20, color: color),
        entries: entries,
        onSelected: (value) {
          if (value == 'edit') onEdit();
          if (value == 'archive') onArchive();
          if (value == 'delete') onDelete();
        },
      ),
    );
  }
}
