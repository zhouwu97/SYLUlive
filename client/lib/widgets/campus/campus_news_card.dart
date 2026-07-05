import 'package:flutter/material.dart';
import '../../models/campus_article.dart';
import 'campus_notice_tag.dart';
import 'campus_theme.dart';

class CampusNewsCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Material(
      color: isDark ? CampusTheme.darkCard : CampusTheme.card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.08) : CampusTheme.softBorder,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部：[分类标签] + 日期
              Row(
                children: [
                  CampusNoticeTag(
                    category: article.category.isNotEmpty ? article.category : '校园资讯',
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
  }
}
