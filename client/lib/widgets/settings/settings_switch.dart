import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 标准 iOS / Material 极简风 Switch 组件 (保证 48dp 推荐无障碍点击区域)
class SettingsSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SettingsSwitch({
    super.key,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary;

    return Switch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: primaryColor,
      inactiveTrackColor: isDark
          ? Colors.white.withValues(alpha: 0.2)
          : const Color(0xFFDCD6CC),
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    );
  }
}
