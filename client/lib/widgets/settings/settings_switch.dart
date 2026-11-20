import 'package:flutter/material.dart';
import '../../theme/app_theme_tokens.dart';

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
    final primaryColor = AppThemeTokens.of(context).primary;

    return Switch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: primaryColor,
      inactiveTrackColor: isDark
          ? Colors.white.withValues(alpha: 0.2)
          : const Color(0xFFDCD6CC), // theme: fixed — 未选中轨道的中性对照色
      // 未选中轨道使用中性色，圆钮随背景角色选择前景以保持可辨认。
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? AppThemeTokens.of(context).onPrimary
              : AppThemeTokens.of(context).textPrimary),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    );
  }
}
