import 'package:flutter/material.dart';
import '../global_background_wrapper.dart';
import '../liquid_glass/liquid_glass_scene.dart';
import '../liquid_glass/liquid_glass_switch.dart';

/// 与桌面端共用胶囊外观；保留原生开关的输入、焦点和无障碍语义。
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
    final source = LiquidGlassScene.maybeOf(context);
    if (source != null && !SharedPageBackground.of(context)) {
      return LiquidGlassSwitch(
          value: value, onChanged: onChanged, source: source, label: '');
    }
    if (MediaQuery.highContrastOf(context)) {
      return Switch(value: value, onChanged: onChanged);
    }

    return Switch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: const Color(0xff2ad34d),
      inactiveTrackColor:
          isDark ? const Color(0xff5b586a) : const Color(0xffcfcbd3),
      activeThumbColor: Colors.white,
      inactiveThumbColor: Colors.white,
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    );
  }
}
