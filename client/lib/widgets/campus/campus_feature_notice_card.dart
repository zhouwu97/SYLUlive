import 'package:flutter/material.dart';
import '../../models/campus_article.dart';

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
    // 渐变色：低饱和清爽紫色
    final gradientColors = [
      const Color(0xFF667EEA),
      const Color(0xFF6B73D6),
    ];

    // 清洗标题中的学期前缀，让标题更清爽 (可选)
    // 假设文章标题为 "2025-2026-2第18周-实验..."
    // 简单替换掉前面的学期标识
    var displayTitle = article.title;
    final regex = RegExp(r'^\d{4}-\d{4}-\d[第-]?\d+周-?');
    if (regex.hasMatch(displayTitle)) {
      displayTitle = displayTitle.replaceFirst(regex, '');
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 116,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF667EEA).withValues(alpha: isDark ? 0.16 : 0.22),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            // 右侧装饰图标
            Positioned(
              right: -10,
              top: -10,
              child: Icon(
                Icons.account_balance_rounded,
                size: 86,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部：[分类] + 日期
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          article.category.isNotEmpty ? article.category : '教务公告',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        article.publishDate.isNotEmpty ? article.shortDate : '',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  // 标题
                  Text(
                    displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 底部：部门 · 附件
                  Text(
                    [
                      if (article.authorDepartment.isNotEmpty) article.authorDepartment,
                      if (article.hasAttachment) '含附件',
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
