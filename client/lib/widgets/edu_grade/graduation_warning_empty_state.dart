import 'package:flutter/material.dart';

class GraduationWarningEmptyState extends StatelessWidget {
  const GraduationWarningEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFFFFC46B) : const Color(0xFFB86B00);
    final secondary = isDark ? Colors.grey.shade400 : const Color(0xFF737A80);

    return Padding(
      key: const ValueKey('graduation_warning_empty_state'),
      padding: const EdgeInsets.fromLTRB(32, 58, 32, 70),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, size: 36, color: accent),
          ),
          const SizedBox(height: 20),
          const Text(
            '功能验证中',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            '正在验证学校培养方案和毕业审核数据来源。\n'
            '当前学业总览仅用于展示 GPA 和课程修读状态，\n'
            '暂不能作为毕业资格判断依据。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: secondary),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '当前数据来源：学校教务系统学业情况页面\n'
              '暂不支持：毕业风险、学分缺口、培养模块与毕业结论\n'
              '后续更新：完成官方数据源验证后再逐步开放',
              style: TextStyle(fontSize: 12, height: 1.6, color: secondary),
            ),
          ),
        ],
      ),
    );
  }
}
