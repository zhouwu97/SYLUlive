import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

class CampusTheme {
  static const Color bg = AppColors.surfacePrimaryLight;
  static const Color darkBg = AppColors.surfacePrimaryDark;

  static Color pageBackground(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? darkBg : bg;
  }

  static const Color card = AppColors.surfaceSecondaryLight;
  static const Color darkCard = AppColors.surfaceSecondaryDark;

  static const Color text = AppColors.textPrimaryLight;
  static const Color subText = AppColors.textSecondaryLight;

  static const Color primary = AppColors.brandPrimary;
  static const Color primaryLight = Color(0xFFEAF6F3);

  static const Color border = AppColors.borderNormalLight;
  static const Color softBorder = AppColors.borderSubtleLight;

  static const Color blue = Color(0xFF2F80ED);
  static const Color orange = Color(0xFFF2994A);
  static const Color green = Color(0xFF10B981);
  static const Color cyan = Color(0xFF0EA5A4);
  static const Color red = Color(0xFFE54848);
  static const Color dining = Color(0xFFE76F51);

  /// 将页面级品牌 accent 注入现有主题，保留原主题的明暗、字体和组件形状。
  ///
  /// 不改全局 AppTheme 的 seed，避免影响尚未完成迁移的业务页面；需要统一
  /// 校园/设置类页面时，在页面边界使用这个方法即可。
  static ThemeData withBrandAccent(ThemeData base) {
    final isDark = base.brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : primary;
    final onAccent = isDark ? darkBg : Colors.white;
    final accentContainer = isDark ? const Color(0xFF1B3B36) : primaryLight;
    final onAccentContainer = isDark ? const Color(0xFFBFEDE3) : primary;

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: onAccent,
        primaryContainer: accentContainer,
        onPrimaryContainer: onAccentContainer,
        secondary: accent,
        onSecondary: onAccent,
        secondaryContainer: accentContainer,
        onSecondaryContainer: onAccentContainer,
      ),
    );
  }

  static BoxDecoration cardDecoration(bool isDark, {bool softGreen = false}) {
    return BoxDecoration(
      color: isDark ? darkCard : card,
      gradient: !isDark && softGreen
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white, Color(0xFFF1FBF7)],
            )
          : null,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(
        color: isDark ? Colors.white.withValues(alpha: 0.08) : border,
      ),
      boxShadow: isDark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.025),
                blurRadius: 12,
                offset: const Offset(0, 5),
              ),
            ],
    );
  }
}
