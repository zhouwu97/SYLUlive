import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../campus/campus_theme.dart';

class CampusSegmentItem<T> {
  final T value;
  final String label;

  const CampusSegmentItem({
    required this.value,
    required this.label,
  });
}

/// 匹配设计稿 100% 的平滑胶囊分段选择器 (支持焦点管理、键盘 Enter/Space 激活与完整无障碍)
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
            child: Semantics(
              button: true,
              selected: isSelected,
              label: item.label,
              child: _CampusSegmentButton<T>(
                item: item,
                isSelected: isSelected,
                isDark: isDark,
                onTap: () => onSelectionChanged(item.value),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _CampusSegmentButton<T> extends StatefulWidget {
  final CampusSegmentItem<T> item;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _CampusSegmentButton({
    required this.item,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_CampusSegmentButton<T>> createState() =>
      __CampusSegmentButtonState<T>();
}

class __CampusSegmentButtonState<T> extends State<_CampusSegmentButton<T>> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onFocusChange: (focused) {
        setState(() => _isFocused = focused);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          focusColor: CampusTheme.primary.withValues(alpha: 0.15),
          highlightColor: CampusTheme.primary.withValues(alpha: 0.08),
          splashColor: CampusTheme.primary.withValues(alpha: 0.12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? (widget.isDark ? const Color(0xFF383C42) : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: _isFocused
                  ? Border.all(
                      color: CampusTheme.primary,
                      width: 2,
                    )
                  : null,
              boxShadow: widget.isSelected
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
                widget.item.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      widget.isSelected ? FontWeight.bold : FontWeight.w500,
                  color: widget.isSelected
                      ? (widget.isDark
                          ? const Color(0xFF7ED6C5)
                          : CampusTheme.primary)
                      : (widget.isDark
                          ? Colors.white60
                          : const Color(0xFF6E7278)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
