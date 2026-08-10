import 'package:flutter/material.dart';
import '../../theme/app_radius.dart';

class CampusTheme {
  static const Color bg = Color(0xFFFFFAF4);
  static const Color darkBg = Color(0xFF111315);

  static Color pageBackground(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? darkBg : bg;
  }

  static const Color card = Color(0xFFFFFFFF);
  static const Color darkCard = Color(0xFF1E2226);

  static const Color text = Color(0xFF1F2328);
  static const Color subText = Color(0xFF747B82);

  static const Color primary = Color(0xFF147C72);
  static const Color primaryLight = Color(0xFFEAF6F3);

  static const Color border = Color(0xFFE2EFEA);
  static const Color softBorder = Color(0xFFE8EEE9);

  static const Color blue = Color(0xFF2F80ED);
  static const Color orange = Color(0xFFF2994A);
  static const Color green = Color(0xFF10B981);
  static const Color cyan = Color(0xFF0EA5A4);
  static const Color red = Color(0xFFE54848);

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
