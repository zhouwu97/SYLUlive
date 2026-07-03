import 'package:flutter/material.dart';
import 'campus_theme.dart';

class CampusNoticeTag extends StatelessWidget {
  final String category;

  const CampusNoticeTag({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    Color textColor;
    Color bgColor;

    final cat = category.isNotEmpty ? category : '校园资讯';

    if (cat.contains('比赛') || cat.contains('竞赛')) {
      textColor = CampusTheme.orange;
      bgColor = const Color(0xFFFFF3E0);
    } else if (cat.contains('教务')) {
      textColor = CampusTheme.blue;
      bgColor = const Color(0xFFEBF5FF);
    } else if (cat.contains('活动')) {
      textColor = CampusTheme.green;
      bgColor = const Color(0xFFE6F4EA);
    } else if (cat.contains('紧急') || cat.contains('重要')) {
      textColor = CampusTheme.red;
      bgColor = const Color(0xFFFFEBEE);
    } else {
      // 默认（如：校园公告）
      textColor = CampusTheme.primary;
      bgColor = CampusTheme.primaryLight;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      bgColor = textColor.withValues(alpha: 0.15);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        cat,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
