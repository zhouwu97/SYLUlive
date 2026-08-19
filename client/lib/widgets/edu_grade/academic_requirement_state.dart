import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// 学分要求模块的状态标签 chip。
///
/// 四个固定状态：
/// - completed   → 已满足
/// - in_progress → 进行中
/// - shortfall   → 待补足
/// - unknown     → 状态未知
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
            ? AppColors.successSurfaceDark
            : AppColors.successSurfaceLight;
        fg = AppColors.success;
        break;
      case 'in_progress':
        bg = isDark
            ? AppColors.brandSurfaceDark
            : AppColors.brandSurfaceLight;
        fg = AppColors.brandPrimary;
        break;
      case 'shortfall':
        bg = isDark
            ? AppColors.warningSurfaceDark
            : AppColors.warningSurfaceLight;
        fg = AppColors.warning;
        break;
      default:
        bg = isDark
            ? AppColors.surfaceMutedDark
            : AppColors.surfaceMutedLight;
        fg = isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
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
