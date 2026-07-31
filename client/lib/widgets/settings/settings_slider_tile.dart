import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 专用的全宽 Slider 设置项组件
class SettingsSliderTile extends StatelessWidget {
  final IconData? icon;
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    color: isDark
                        ? const Color(0xFF7ED6C5).withValues(alpha: 0.15)
                        : CampusTheme.primaryLight,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    icon,
                    size: 22,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : CampusTheme.text,
                  ),
                ),
              ),
              Text(
                valueText,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: primaryColor,
                ),
              ),
            ],
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: EdgeInsets.only(left: icon != null ? 52 : 0),
              child: Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: isDark ? Colors.white60 : CampusTheme.subText,
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.only(left: icon != null ? 40 : 0),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: onChanged,
                activeColor: primaryColor,
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
