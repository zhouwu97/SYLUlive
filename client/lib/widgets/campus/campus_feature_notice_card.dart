import 'package:flutter/material.dart';
import '../../models/campus_article.dart';
import 'campus_theme.dart';
import 'campus_notice_tag.dart';

class CampusFeatureNoticeCard extends StatelessWidget {
  final CampusArticleSummary article;
  final bool isDark;
  final VoidCallback onTap;

  const CampusFeatureNoticeCard({
    super.key,
    required this.article,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 清洗标题中的学期前缀，让标题更清爽 (可选)
    // 假设文章标题为 "2025-2026-2第18周-实验..."
    // 简单替换掉前面的学期标识
    var displayTitle = article.title;
    final regex = RegExp(r'^\d{4}-\d{4}-\d[第-]?\d+周-?');
    if (regex.hasMatch(displayTitle)) {
      displayTitle = displayTitle.replaceFirst(regex, '');
    }

    final department = article.authorDepartment.isNotEmpty 
        ? article.authorDepartment 
        : '';
        
    final departmentInfo = [
      if (department.isNotEmpty) department,
      if (article.hasAttachment) '含附件',
    ].join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 112),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            decoration: CampusTheme.cardDecoration(isDark, softGreen: true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CampusNoticeTag(
                      category: article.category.isNotEmpty ? article.category : '教务公告'
                    ),
                    const Spacer(),
                    Text(
                      article.publishDate.isNotEmpty ? article.shortDate : '',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : CampusTheme.subText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.28,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : CampusTheme.text,
                  ),
                ),
                if (departmentInfo.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    departmentInfo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: isDark ? Colors.white54 : CampusTheme.subText,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
