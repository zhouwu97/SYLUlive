import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 设置页分组卡片组件
class SettingsSection extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const SettingsSection({
    super.key,
    this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor =
        isDark ? Colors.white.withValues(alpha: 0.06) : CampusTheme.softBorder;

    final List<Widget> cardItems = [];
    for (int i = 0; i < children.length; i++) {
      cardItems.add(children[i]);
      if (i < children.length - 1) {
        cardItems.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 62,
            endIndent: 16,
            color: dividerColor,
          ),
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title!.trim().isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                title!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : CampusTheme.subText,
                ),
              ),
            ),
          ],
          Container(
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : CampusTheme.softBorder,
              ),
              boxShadow: isDark
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.025),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: cardItems,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
