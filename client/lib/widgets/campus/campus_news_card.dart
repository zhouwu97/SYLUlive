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
      color: isDark ? const Color(0xFF1B1E28) : CampusTheme.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? Colors.white10 : const Color(0xFFF0F1F5),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : CampusTheme.subText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // 标题（最多两行）
              Text(
                article.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.28,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : CampusTheme.text,
                ),
              ),
              const SizedBox(height: 4),
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
                          color: isDark ? Colors.white38 : CampusTheme.subText.withValues(alpha: 0.8),
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
                        color: isDark ? Colors.white24 : CampusTheme.subText.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                  if (article.hasAttachment) ...[
                    Icon(
                      Icons.attach_file_rounded,
                      size: 13,
                      color: isDark ? Colors.white38 : CampusTheme.subText,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '含附件',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : CampusTheme.subText,
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
