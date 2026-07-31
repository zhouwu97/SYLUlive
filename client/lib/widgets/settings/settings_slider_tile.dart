import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 专用的全宽 Slider 设置项组件 (支持多彩图标与紧凑布局)
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
  final String valueText;

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
    required this.valueText,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary;

    final effectiveIconColor = iconColor ?? primaryColor;
    final effectiveIconBgColor = iconBgColor ??
        (isDark
            ? const Color(0xFF7ED6C5).withValues(alpha: 0.15)
            : CampusTheme.primaryLight);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: effectiveIconBgColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: effectiveIconColor,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : CampusTheme.text,
                  ),
                ),
              ),
              Text(
                valueText,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: effectiveIconColor,
                ),
              ),
            ],
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Padding(
              padding: EdgeInsets.only(left: icon != null ? 48 : 0),
              child: Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  color: isDark ? Colors.white60 : CampusTheme.subText,
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.only(left: icon != null ? 36 : 0),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: onChanged,
                activeColor: effectiveIconColor,
                inactiveColor: isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : CampusTheme.softBorder,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
