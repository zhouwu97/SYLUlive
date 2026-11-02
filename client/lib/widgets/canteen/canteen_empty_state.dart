import 'package:flutter/material.dart';

import 'canteen_theme.dart';
import '../app_card.dart';

/// 轻量空状态：保留原有尺寸与留白，壁纸模式补充文字承托底面。
/// 用于评价区 / 搜索无结果 / 菜品图鉴空态。
class CanteenEmptyState extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? icon;
  final double minHeight;

  const CanteenEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.icon,
    this.minHeight = 120,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AppContentSurface.card(
        child: Container(
      constraints: BoxConstraints(minHeight: minHeight),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 26, color: CanteenTheme.textTertiaryColor(isDark)),
            const SizedBox(height: 10),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: appContentSecondaryColor(
                    context, CanteenTheme.textSecondaryColor(isDark)),
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: CanteenTheme.accentStrongColor(isDark),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    ));
  }
}
