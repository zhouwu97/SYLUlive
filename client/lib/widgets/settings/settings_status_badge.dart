import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

enum SettingsStatusBadgeType {
  success,
  info,
  warning,
  danger,
  neutral,
}

/// 设置状态标签胶囊
class SettingsStatusBadge extends StatelessWidget {
  final String label;
  final SettingsStatusBadgeType type;

  const SettingsStatusBadge({
    super.key,
    required this.label,
    this.type = SettingsStatusBadgeType.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color textColor;
    Color bgColor;

    switch (type) {
      case SettingsStatusBadgeType.success:
        textColor = CampusTheme.green;
        bgColor = CampusTheme.green.withValues(alpha: isDark ? 0.2 : 0.1);
        break;
      case SettingsStatusBadgeType.info:
        textColor = CampusTheme.blue;
        bgColor = CampusTheme.blue.withValues(alpha: isDark ? 0.2 : 0.1);
        break;
      case SettingsStatusBadgeType.warning:
        textColor = CampusTheme.orange;
        bgColor = CampusTheme.orange.withValues(alpha: isDark ? 0.2 : 0.1);
        break;
      case SettingsStatusBadgeType.danger:
        textColor = CampusTheme.red;
        bgColor = CampusTheme.red.withValues(alpha: isDark ? 0.2 : 0.1);
        break;
      case SettingsStatusBadgeType.neutral:
        textColor = isDark ? Colors.white60 : CampusTheme.subText;
        bgColor = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.grey.withValues(alpha: 0.12);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}
