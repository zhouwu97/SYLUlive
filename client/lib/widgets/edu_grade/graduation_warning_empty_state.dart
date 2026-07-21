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
            '暂无毕业预警数据',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            '当前仅提供页面入口，暂未接入预警数据。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: secondary),
          ),
        ],
      ),
    );
  }
}
