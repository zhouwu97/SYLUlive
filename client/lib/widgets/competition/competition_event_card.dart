import 'package:flutter/material.dart';

import '../../models/competition.dart';
import 'competition_status_helper.dart';
import 'competition_ui_tokens.dart';

class CompetitionEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final bool isAdmin;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onAddPlan;
  final VoidCallback? onEdit;
  final VoidCallback? onPublish;
  final VoidCallback? onArchive;

  const CompetitionEventCard({
    super.key,
    required this.event,
    this.isAdmin = false,
    this.selectionMode = false,
    this.isSelected = false,
    required this.onTap,
    required this.onAddPlan,
    this.onEdit,
    this.onPublish,
    this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    if (isAdmin) {
      return CompetitionAdminEventCard(
        event: event,
        selectionMode: selectionMode,
        isSelected: isSelected,
        onTap: onTap,
        onEdit: onEdit,
        onPublish: onPublish,
        onArchive: onArchive,
      );
    }
    return CompetitionStudentEventCard(
      event: event,
      onTap: onTap,
      onAddPlan: onAddPlan,
    );
  }
}

class CompetitionStudentEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final VoidCallback onTap;
  final VoidCallback onAddPlan;

  const CompetitionStudentEventCard({
    super.key,
    required this.event,
    required this.onTap,
    required this.onAddPlan,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = resolveCompetitionStatus(event, isDark);
    final targetAudience = event.targetAudience.trim();
    final reason = event.recommendationReason.trim();

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
                  const SizedBox(width: 10),
                  _solidPill(
                    event.recommendationLevel.isEmpty
                        ? 'B'
                        : event.recommendationLevel,
                    CompetitionUiTokens.accent(isDark),
                    isDark,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (event.competitionLevel.isNotEmpty)
                    _softPill(event.competitionLevel, isDark),
                  if (event.schoolRecognitionGrade.isNotEmpty)
                    _softPill('学校目录 ${event.schoolRecognitionGrade}', isDark),
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
              if (targetAudience.isNotEmpty) ...[
                const SizedBox(height: 6),
                _infoLine(
                    Icons.groups_2_outlined, '适合：$targetAudience', isDark),
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
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (event.schoolRecognitionStatus == 'recognized')
                          _outlinePill('学校认定', isDark),
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
                    onPressed: onAddPlan,
                    icon: const Icon(Icons.add_rounded, size: 17),
                    label: const Text('加入计划'),
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

class CompetitionAdminEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onPublish;
  final VoidCallback? onArchive;

  const CompetitionAdminEventCard({
    super.key,
    required this.event,
    this.selectionMode = false,
    this.isSelected = false,
    required this.onTap,
    this.onEdit,
    this.onPublish,
    this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chips = _adminChips(event);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectionMode) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 10, top: 2),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => onTap(),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.26,
                        fontWeight: FontWeight.w900,
                        color: CompetitionUiTokens.titleColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children:
                          chips.map((chip) => _softPill(chip, isDark)).toList(),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        _compactInfo(
                          Icons.category_outlined,
                          event.primaryCategory?.name ?? '未分类',
                          isDark,
                        ),
                        _compactInfo(
                          Icons.source_outlined,
                          competitionSourceLabel(event.sourceChannel),
                          isDark,
                        ),
                        _compactInfo(
                          Icons.update_rounded,
                          _updatedText(event.updatedAt),
                          isDark,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!selectionMode) ...[
                const SizedBox(width: 8),
                Column(
                  children: [
                    if (onPublish != null)
                      FilledButton(
                        onPressed: onPublish,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          backgroundColor: CompetitionUiTokens.accent(isDark),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('发布'),
                      ),
                    TextButton(
                      onPressed: onEdit,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: CompetitionUiTokens.titleColor(isDark),
                      ),
                      child: const Text('编辑'),
                    ),
                    if (onArchive != null)
                      PopupMenuButton<String>(
                        tooltip: '更多操作',
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          color: CompetitionUiTokens.subColor(isDark),
                        ),
                        onSelected: (value) {
                          if (value == 'archive') onArchive?.call();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'archive',
                            child: Text('归档'),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
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

Widget _compactInfo(IconData icon, String text, bool isDark) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: CompetitionUiTokens.subColor(isDark)),
      const SizedBox(width: 4),
      Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: CompetitionUiTokens.subColor(isDark),
          fontWeight: FontWeight.w600,
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

List<String> _adminChips(CompetitionEvent event) {
  final chips = <String>[
    _statusText(event.status),
    event.timeStatusLabel,
  ];
  if (event.registrationEnd == null && event.registrationTimeText.isEmpty) {
    chips.add('缺时间');
  }
  if (event.officialUrl.isEmpty && event.noticeUrl.isEmpty) {
    chips.add('缺官网');
  }
  if (event.recommendationLevel.isNotEmpty) {
    chips.add(event.recommendationLevel);
  }
  if (event.schoolRecognitionGrade.isNotEmpty) {
    chips.add(event.schoolRecognitionGrade);
  }
  return chips;
}

String _statusText(String status) {
  switch (status) {
    case 'draft':
      return '草稿';
    case 'published':
      return '已发布';
    case 'archived':
      return '已归档';
    default:
      return status.isEmpty ? '未知状态' : status;
  }
}

String _updatedText(DateTime? updatedAt) {
  if (updatedAt == null) return '未更新';
  return '${updatedAt.year}-${updatedAt.month.toString().padLeft(2, '0')}-${updatedAt.day.toString().padLeft(2, '0')}';
}
