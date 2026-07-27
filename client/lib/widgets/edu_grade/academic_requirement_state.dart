/// 学分要求模块的状态标签 chip。
///
/// 四个固定状态：
/// - completed   → 已满足
/// - in_progress → 进行中
/// - shortfall   → 待补足
/// - unknown     → 状态未知

import 'package:flutter/material.dart';

class AcademicRequirementState extends StatefulWidget {
  final String status;

  const AcademicRequirementState({
    super.key,
    required this.status,
  });

  @override
  State<AcademicRequirementState> createState() =>
      _AcademicRequirementStateState();
}

class _AcademicRequirementStateState extends State<AcademicRequirementState> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color bg;
    final Color fg;

    switch (widget.status) {
      case 'completed':
        bg = isDark
            ? const Color(0xFF7ED6C5).withValues(alpha: 0.14)
            : const Color(0xFF147C72).withValues(alpha: 0.1);
        fg = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
        break;
      case 'in_progress':
        bg = isDark
            ? const Color(0xFFF4B860).withValues(alpha: 0.14)
            : const Color(0xFFC47C14).withValues(alpha: 0.1);
        fg = isDark ? const Color(0xFFF4B860) : const Color(0xFFC47C14);
        break;
      case 'shortfall':
        bg = isDark
            ? const Color(0xFFE36B5E).withValues(alpha: 0.12)
            : const Color(0xFFC62828).withValues(alpha: 0.08);
        fg = isDark ? const Color(0xFFE36B5E) : const Color(0xFFC62828);
        break;
      default:
        bg = isDark
            ? Colors.grey.shade700.withValues(alpha: 0.3)
            : Colors.grey.shade200;
        fg = isDark ? Colors.grey.shade400 : const Color(0xFF737A80);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  String get _label {
    switch (widget.status) {
      case 'completed':
        return '已满足';
      case 'in_progress':
        return '进行中';
      case 'shortfall':
        return '待补足';
      case 'unknown':
        return '状态未知';
      default:
        return widget.status;
    }
  }
}
