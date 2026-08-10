import 'package:flutter/material.dart';
import '../../models/campus_article.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';
import 'campus_notice_tag.dart';
import 'campus_theme.dart';

class CampusNewsCard extends StatefulWidget {
  final CampusArticleSummary article;
  final bool isDark;
  final VoidCallback onTap;

  const CampusNewsCard({
    super.key,
    required this.article,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<CampusNewsCard> createState() => _CampusNewsCardState();
}

class _CampusNewsCardState extends State<CampusNewsCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    final isDark = widget.isDark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final surface = Material(
      color: isDark ? CampusTheme.darkCard : CampusTheme.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (highlighted) {
          if (mounted) setState(() => _pressed = highlighted);
        },
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : AppMotion.micro,
          curve: AppMotion.standard,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: _pressed
                  ? CampusTheme.primary.withValues(alpha: isDark ? 0.3 : 0.18)
                  : isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : CampusTheme.softBorder,
            ),
            boxShadow: _pressed
                ? [
                    BoxShadow(
                      color: CampusTheme.primary.withValues(alpha: 0.08),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部：[分类标签] + 日期
              Row(
                children: [
                  CampusNoticeTag(
                    category:
                        article.category.isNotEmpty ? article.category : '校园资讯',
                  ),
                  const Spacer(),
                  Text(
                    article.shortDate,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CampusTheme.subText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 标题（最多两行）
              Text(
                article.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.32,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : CampusTheme.text,
                ),
              ),
              const SizedBox(height: 6),
              // 部门 · 附件状态
              Row(
                children: [
                  if (article.authorDepartment.isNotEmpty) ...[
                    Flexible(
                      child: Text(
                        article.authorDepartment,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: CampusTheme.subText.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                  if (article.authorDepartment.isNotEmpty &&
                      article.hasAttachment) ...[
                    Text(
                      ' · ',
                      style: TextStyle(
                        fontSize: 12,
                        color: CampusTheme.subText.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                  if (article.hasAttachment) ...[
                    Icon(
                      Icons.attach_file_rounded,
                      size: 13,
                      color: CampusTheme.subText.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '含附件',
                      style: TextStyle(
                        fontSize: 12,
                        color: CampusTheme.subText.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (reduceMotion) return surface;
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1.0,
      duration: AppMotion.micro,
      curve: AppMotion.standard,
      child: surface,
    );
  }
}
