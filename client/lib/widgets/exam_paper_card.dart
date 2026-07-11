import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/api_constants.dart';
import '../models/exam_paper.dart';
import 'cached_avatar.dart';
import 'glass_container.dart';
import 'exam_papers/exam_paper_status_badge.dart';

class ExamPaperCard extends StatelessWidget {
  final ExamPaper paper;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? footer;
  final bool showStatus;

  const ExamPaperCard({
    super.key,
    required this.paper,
    required this.onTap,
    this.trailing,
    this.footer,
    this.showStatus = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final publishedTime =
        paper.publishedAt?.toLocal() ?? paper.createdAt.toLocal();

    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  paper.courseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
              if (showStatus) ...[
                const SizedBox(width: 10),
                ExamPaperStatusBadge(status: paper.status),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _MetaChip(
                  icon: Icons.calendar_today_outlined,
                  text: paper.academicYear),
              _MetaChip(
                  icon: Icons.menu_book_outlined, text: paper.semesterLabel),
              _MetaChip(
                  icon: Icons.assignment_outlined, text: paper.examTypeLabel),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              CachedAvatar(
                imageUrl: paper.contributor.avatar.isEmpty
                    ? null
                    : ApiConstants.fullUrl(paper.contributor.avatar),
                radius: 15,
                fallbackText: paper.contributor.nickname,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${paper.contributor.nickname} · Lv.${paper.contributor.level}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                Icons.download_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '${paper.downloadCount}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 10),
              Text(
                DateFormat('MM-dd').format(publishedTime),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
          if (footer != null) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 10),
            footer!,
          ],
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}
