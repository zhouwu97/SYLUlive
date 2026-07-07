import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';

class GradeCourseItem extends StatelessWidget {
  final EduGrade grade;
  final VoidCallback? onTap;

  const GradeCourseItem({
    super.key,
    required this.grade,
    this.onTap,
  });

  static Color gradeColor(
    String displayGrade,
    bool? isPassed,
    BuildContext context,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isPassed == false) {
      return isDark ? const Color(0xFFFF8A80) : const Color(0xFFD64545);
    }
    return isDark ? Colors.white : const Color(0xFF1F2328);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scoreColor = gradeColor(grade.displayGrade, grade.isPassed, context);

    final cardColor = isDark ? const Color(0xFF1E2226) : Colors.white;
    final borderColor =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE8EEE9);
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final metaColor = isDark ? Colors.grey.shade400 : const Color(0xFF747B82);

    final gpaText = grade.gpa != null
        ? '绩点 ${grade.gpa!.toStringAsFixed(2)}'
        : '绩点 --';

    final content = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 13),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.025),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: grade.isPassed == false
                      ? (isDark ? const Color(0xFFFF8A80) : const Color(0xFFE54848))
                      : grade.isDegree
                          ? (isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72))
                          : (isDark ? const Color(0xFF5E646A) : const Color(0xFFD6DFDA)),
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(
                child: Text(
                  grade.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                grade.displayGrade,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _scoreFontSize(grade.displayGrade),
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: scoreColor,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 3),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 21,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade400,
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${grade.credits.toStringAsFixed(1)} 学分 · $gpaText',
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              color: metaColor,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (grade.isDegree || grade.isPassed == false) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (grade.isDegree) _tag(context, '学位课', _TagTone.neutral),
                if (grade.isPassed == false) _tag(context, '未通过', _TagTone.danger),
              ],
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: content,
      ),
    );
  }

  double _scoreFontSize(String value) {
    final text = value.trim();
    if (text.length >= 3 && double.tryParse(text) == null) {
      return 22;
    }
    return 24;
  }

  Widget _tag(BuildContext context, String label, _TagTone tone) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    late final Color bg;
    late final Color fg;

    switch (tone) {
      case _TagTone.danger:
        bg = isDark
            ? const Color(0xFF4A2525)
            : const Color(0xFFFFEEEE);
        fg = isDark
            ? const Color(0xFFFFB4B4)
            : const Color(0xFFC84242);
        break;
      case _TagTone.neutral:
        bg = isDark
            ? Colors.white.withValues(alpha: 0.07)
            : const Color(0xFFEAF6F3);
        fg = isDark
            ? const Color(0xFF7ED6C5)
            : const Color(0xFF147C72);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

enum _TagTone {
  neutral,
  danger,
}
