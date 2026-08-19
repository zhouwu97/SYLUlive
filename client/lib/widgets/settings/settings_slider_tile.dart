import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 专用的全宽 Slider 设置项组件 (支持 valueText / valueLabel 兼容)
class SettingsSliderTile extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBgColor;
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? valueText;
  final String? valueLabel;
  final bool enabled;

  const SettingsSliderTile({
    super.key,
    this.icon,
    this.iconColor,
    this.iconBgColor,
    required this.title,
    this.subtitle,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    required this.onChanged,
    this.valueText,
    this.valueLabel,
    this.enabled = true,
  });

  String get _displayValueText => valueText ?? valueLabel ?? '';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary;

    final effectiveIconColor = iconColor ?? primaryColor;
    final effectiveIconBgColor = iconBgColor ??
        (isDark
            ? const Color(0xFF7ED6C5).withValues(alpha: 0.15)
            : CampusTheme.primaryLight);

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: effectiveIconBgColor,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      icon,
                      size: 22,
                      color: effectiveIconColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : CampusTheme.text,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12.5,
                            color:
                                isDark ? Colors.white60 : CampusTheme.subText,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_displayValueText.isNotEmpty)
                  Text(
                    _displayValueText,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: primaryColor,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: primaryColor,
                inactiveTrackColor: isDark
                    ? Colors.white.withValues(alpha: 0.15)
                    : const Color(0xFFE5E0D8),
                thumbColor: primaryColor,
                overlayColor: primaryColor.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 9,
                  elevation: 2,
                ),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
