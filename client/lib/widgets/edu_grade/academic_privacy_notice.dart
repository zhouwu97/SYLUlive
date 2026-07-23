import 'package:flutter/material.dart';

/// 学业总览固定隐私与用途边界，避免统计结果被误解为毕业审核结论。
class AcademicPrivacyNotice extends StatelessWidget {
  const AcademicPrivacyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('academic_privacy_notice'),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.privacy_tip_outlined,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '学业数据来自学校教务系统，仅供本人查看。\n'
              '页面中的统计不代表学校毕业审核结论。',
              style: TextStyle(
                fontSize: 12,
                height: 1.55,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
