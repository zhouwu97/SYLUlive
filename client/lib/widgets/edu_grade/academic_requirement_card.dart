/// 学分要求模块卡片。
///
/// 展示单个学分模块的进度条、最低要求学分、已获得学分和状态。

import 'package:flutter/material.dart';
import '../../models/edu_credit_requirement.dart';
import 'academic_requirement_state.dart';

class AcademicRequirementCard extends StatelessWidget {
  final EduCreditRequirementModule module;
  final VoidCallback? onTap;

  const AcademicRequirementCard({
    super.key,
    required this.module,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF737A80);
    final cardBg =
        isDark ? const Color(0xFF1A1D21) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : const Color(0xFFE2E6EB);
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

    final progress = module.progress;
    final hasRequirement = module.hasRequiredCredits;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 模块名称 + 状态标签
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        module.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: titleColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AcademicRequirementState(status: module.status),
                  ],
                ),
                const SizedBox(height: 12),

                // 学分数字
                RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: accent,
                      height: 1.2,
                    ),
                    children: [
                      TextSpan(
                        text: '${_formatCredits(module.earnedCredits)}',
                      ),
                      if (hasRequirement) ...[
                        TextSpan(
                          text: ' / ${_formatCredits(module.requiredCredits!)}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: subColor,
                          ),
                        ),
                      ],
                      TextSpan(
                        text: ' 学分',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: subColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                // 进度条（仅在有最低要求时显示）
                if (hasRequirement) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFE8ECEF),
                      color: _progressColor(module.status),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // 超出/不足说明
                if (hasRequirement) ...[
                  Text(
                    module.creditDeltaText,
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                ] else ...[
                  Text(
                    '已获得 ${_formatCredits(module.earnedCredits)} 学分',
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                ],
                const SizedBox(height: 6),

                // 底部：课程门数 + 箭头
                Row(
                  children: [
                    Text(
                      '${module.completedCourseCount} 门课程',
                      style: TextStyle(fontSize: 12, color: subColor),
                    ),
                    const Spacer(),
                    if (onTap != null)
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade400,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatCredits(double credits) {
    return credits.toStringAsFixed(
      credits.truncateToDouble() == credits ? 0 : 1,
    );
  }

  Color _progressColor(String status) {
    switch (status) {
      case 'completed':
        return const Color(0xFF147C72);
      case 'in_progress':
        return const Color(0xFFC47C14);
      case 'shortfall':
        return const Color(0xFFC62828);
      default:
        return const Color(0xFF9EA7B0);
    }
  }
}
