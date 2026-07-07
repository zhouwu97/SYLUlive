import 'package:flutter/material.dart';

class AppPopupAction {
  final String value;
  final String label;
  final IconData icon;
  final bool danger;
  final bool enabled;

  const AppPopupAction({
    required this.value,
    required this.label,
    required this.icon,
    this.danger = false,
    this.enabled = true,
  });
}

class AppActionPopupMenu extends StatelessWidget {
  final Widget icon;
  final List<Object> entries;
  final ValueChanged<String> onSelected;
  final double width;
  final Offset offset;
  final Color? accentColor;
  final Color? dangerColor;

  const AppActionPopupMenu({
    super.key,
    required this.icon,
    required this.entries,
    required this.onSelected,
    this.width = 180,
    this.offset = const Offset(0, 8),
    this.accentColor,
    this.dangerColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E2226) : Colors.white;
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE8E8E8);
    final textColor = isDark ? Colors.white : const Color(0xFF222222);
    final subColor = isDark ? Colors.white70 : const Color(0xFF666666);
    final danger = dangerColor ?? const Color(0xFFE54848);
    final accent = accentColor ?? const Color(0xFF147C72);

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      tooltip: '更多操作',
      icon: icon,
      position: PopupMenuPosition.under,
      offset: offset,
      color: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      constraints: BoxConstraints.tightFor(width: width),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: border),
      ),
      onSelected: onSelected,
      itemBuilder: (context) {
        final result = <PopupMenuEntry<String>>[];

        for (final entry in entries) {
          if (entry is Divider) {
            result.add(const PopupMenuDivider(height: 8));
          } else if (entry is AppPopupAction) {
            final itemColor = entry.danger
                ? danger
                : entry.enabled
                    ? textColor
                    : subColor;

            result.add(
              PopupMenuItem<String>(
                value: entry.value,
                enabled: entry.enabled,
                height: 44,
                child: Row(
                  children: [
                    Icon(
                      entry.icon,
                      size: 18,
                      color: entry.danger ? danger : accent,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.1,
                          color: itemColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        }

        return result;
      },
    );
  }
}
