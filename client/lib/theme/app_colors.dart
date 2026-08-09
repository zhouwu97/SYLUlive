import 'package:flutter/material.dart';

/// 全局颜色 token。
///
/// `accentIndigo` 暂时保留为 Material 的 legacy seed；切换到
/// `brandPrimary` 属于 PR5A-1，必须在 Golden/视觉 QA 就绪后单独验收。
abstract final class AppColors {
  static const brandPrimary = Color(0xFF147C72);
  static const accentIndigo = Color(0xFF6366F1);
  static const accentPurple = Color(0xFF8B5CF6);
  static const accentPink = Color(0xFFEC4899);

  static const surfacePrimaryLight = Color(0xFFFFFAF4);
  static const surfaceSecondaryLight = Colors.white;
  static const surfacePrimaryDark = Color(0xFF111315);
  static const surfaceSecondaryDark = Color(0xFF1E2226);

  static const textPrimaryLight = Color(0xFF1F2328);
  static const textSecondaryLight = Color(0xFF747B82);
  static const borderNormalLight = Color(0xFFE2EFEA);
  static const borderSubtleLight = Color(0xFFE8EEE9);
}
