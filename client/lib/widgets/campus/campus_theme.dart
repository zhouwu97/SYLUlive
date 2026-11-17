import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';

class CampusTheme {
  static const Color bg = AppColors.surfacePrimaryLight;
  static const Color darkBg = AppColors.surfacePrimaryDark;

  static Color pageBackground(BuildContext context) {
    return AppThemeTokens.of(context).background;
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
    final palette =
        base.extension<AppPalette>() ?? AppPalette.defaults(base.brightness);
    final accent = palette.primary;
    final onAccent = palette.onPrimary;
    final accentContainer = palette.primaryContainer;
    final onAccentContainer = palette.onPrimaryContainer;

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

  /// 旧装饰入口保留给未迁移页面，首批组件使用当前 Token 和圆角。
  static BoxDecoration themedCardDecoration(BuildContext context,
      {bool softGreen = false}) {
    final tokens = AppThemeTokens.of(context);
    return BoxDecoration(
      color: tokens.card,
      gradient: !tokens.isDark && softGreen
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [tokens.card, tokens.primaryContainer],
            )
          : null,
      borderRadius: BorderRadius.circular(AppShape.of(context).lg),
      border: Border.all(color: tokens.cardBorder),
      boxShadow: tokens.isDark
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
