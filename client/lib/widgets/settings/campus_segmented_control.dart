import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

class CampusSegmentItem<T> {
  final T value;
  final String label;

  const CampusSegmentItem({
    required this.value,
    required this.label,
  });
}

/// 匹配设计稿 100% 的平滑胶囊分段选择器
class CampusSegmentedControl<T> extends StatelessWidget {
  final List<CampusSegmentItem<T>> items;
  final T selectedValue;
  final ValueChanged<T> onSelectionChanged;

  const CampusSegmentedControl({
    super.key,
    required this.items,
    required this.selectedValue,
    required this.onSelectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF26292E) : const Color(0xFFEFECE6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: items.map((item) {
          final isSelected = item.value == selectedValue;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelectionChanged(item.value),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                decoration: BoxDecoration(
                  color: isSelected
                      ? (isDark ? const Color(0xFF383C42) : Colors.white)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected
                          ? (isDark
                              ? const Color(0xFF7ED6C5)
                              : CampusTheme.primary)
                          : (isDark ? Colors.white60 : const Color(0xFF6E7278)),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
