import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 标准设置列表项组件 (恢复舒适高档间距与图标尺寸)
class SettingsTile extends StatelessWidget {
  final IconData? icon;
  final Widget? customIcon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool danger;
  final Color? iconColor;
  final Color? iconBgColor;
  final bool showChevron;
  final int maxSubtitleLines;

  const SettingsTile({
    super.key,
    this.icon,
    this.customIcon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.danger = false,
    this.iconColor,
    this.iconBgColor,
    this.showChevron = true,
    this.maxSubtitleLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final effectiveIconColor = danger
        ? CampusTheme.red
        : (iconColor ??
            (isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary));

    final effectiveIconBgColor = danger
        ? CampusTheme.red.withValues(alpha: 0.1)
        : (iconBgColor ??
            (isDark
                ? const Color(0xFF7ED6C5).withValues(alpha: 0.15)
                : CampusTheme.primaryLight));

    final titleColor =
        danger ? CampusTheme.red : (isDark ? Colors.white : CampusTheme.text);

    final subtitleColor = isDark ? Colors.white60 : CampusTheme.subText;

    Widget? leadingWidget;
    if (customIcon != null) {
      leadingWidget = customIcon;
    } else if (icon != null) {
      leadingWidget = Container(
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
      );
    }

    Widget? trailingWidget = trailing;
    if (trailingWidget == null && onTap != null && showChevron) {
      trailingWidget = Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: isDark
            ? Colors.white.withValues(alpha: 0.3)
            : CampusTheme.subText.withValues(alpha: 0.5),
      );
    }

    final tileContent = Container(
      constraints: const BoxConstraints(minHeight: 62),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          if (leadingWidget != null) ...[
            leadingWidget,
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2.5),
                  Text(
                    subtitle!,
                    maxLines: maxSubtitleLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.28,
                      color: subtitleColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailingWidget != null) ...[
            const SizedBox(width: 8),
            trailingWidget,
          ],
        ],
      ),
    );

    if (!enabled || onTap == null) {
      return Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: tileContent,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: tileContent,
      ),
    );
  }
}
