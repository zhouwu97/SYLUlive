import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme_tokens.dart';
import '../app_card.dart';

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
    return AppCardSurface(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppThemeTokens.of(context).surfaceMuted,
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
  final VoidCallback onTap;

  const _CampusSegmentButton({
    required this.item,
    required this.isSelected,
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
          focusColor:
              AppThemeTokens.of(context).primary.withValues(alpha: 0.15),
          highlightColor:
              AppThemeTokens.of(context).primary.withValues(alpha: 0.08),
          splashColor:
              AppThemeTokens.of(context).primary.withValues(alpha: 0.12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppThemeTokens.of(context).surfaceElevated
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: _isFocused
                  ? Border.all(
                      color: AppThemeTokens.of(context).primary,
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
                      ? (AppThemeTokens.of(context).primary)
                      : (AppThemeTokens.of(context).textSecondary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
