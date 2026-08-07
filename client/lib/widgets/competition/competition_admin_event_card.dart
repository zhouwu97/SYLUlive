import 'package:flutter/material.dart';

import '../../models/competition.dart';
import 'competition_status_helper.dart';
import 'competition_ui_tokens.dart';

class CompetitionAdminEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onPublish;
  final VoidCallback? onArchive;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;

  const CompetitionAdminEventCard({
    super.key,
    required this.event,
    this.selectionMode = false,
    this.isSelected = false,
    required this.onTap,
    this.onEdit,
    this.onPublish,
    this.onArchive,
    this.onRestore,
    this.onDelete,
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
                          _sourceText(event),
                          isDark,
                        ),
                        if (event.updatedAt != null)
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
                    if (!event.mutable)
                      OutlinedButton.icon(
                        onPressed: onTap,
                        icon: const Icon(Icons.lock_outline_rounded, size: 15),
                        label: const Text('目录只读'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          foregroundColor: CompetitionUiTokens.subColor(isDark),
                          side: BorderSide(
                            color: CompetitionUiTokens.borderColor(isDark),
                          ),
                        ),
                      )
                    else if (event.status == 'draft' && onPublish != null)
                      FilledButton(
                        onPressed: onPublish,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          backgroundColor: CompetitionUiTokens.accent(isDark),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('发布'),
                      )
                    else if (event.status == 'published' && onEdit != null)
                      FilledButton(
                        onPressed: onEdit,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          backgroundColor: CompetitionUiTokens.accent(isDark),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('编辑'),
                      )
                    else if (event.status == 'archived' && onRestore != null)
                      FilledButton(
                        onPressed: onRestore,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          backgroundColor: CompetitionUiTokens.accent(isDark),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('恢复草稿'),
                      ),
                    if (event.mutable)
                      PopupMenuButton<String>(
                        tooltip: '更多操作',
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          color: CompetitionUiTokens.subColor(isDark),
                        ),
                        onSelected: (value) {
                          if (value == 'edit') onEdit?.call();
                          if (value == 'archive') onArchive?.call();
                          if (value == 'delete') onDelete?.call();
                        },
                        itemBuilder: (_) => [
                          if (event.status != 'published')
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('编辑'),
                            ),
                          if (event.status != 'archived')
                            const PopupMenuItem(
                              value: 'archive',
                              child: Text('归档'),
                            ),
                          if (event.status != 'published')
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除',
                                  style: TextStyle(color: Colors.red)),
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

Widget _compactInfo(IconData icon, String text, bool isDark) {
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 180),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: CompetitionUiTokens.subColor(isDark)),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: CompetitionUiTokens.subColor(isDark),
              fontWeight: FontWeight.w600,
            ),
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

List<String> _adminChips(CompetitionEvent event) {
  final chips = <String>[
    _statusText(event.status),
    event.timeStatusLabel,
  ];

  final manualLabel = competitionManualRatingShort(event.recommendationLevel);
  if (manualLabel.isNotEmpty) {
    chips.add(manualLabel);
  }

  final schoolLabel = competitionSchoolRecognitionShort(
    status: event.schoolRecognitionStatus,
    grade: event.schoolRecognitionGrade,
  );
  if (schoolLabel.isNotEmpty) {
    chips.add(schoolLabel);
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

String _sourceText(CompetitionEvent event) {
  final source = competitionSourceLabel(event.sourceChannel);
  if (event.sourceNote.trim().isEmpty) return source;
  return '$source · ${event.sourceNote.trim()}';
}

String _updatedText(DateTime? updatedAt) {
  if (updatedAt == null) return '';
  return '${updatedAt.year}-${updatedAt.month.toString().padLeft(2, '0')}-${updatedAt.day.toString().padLeft(2, '0')}';
}
