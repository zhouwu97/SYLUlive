import 'package:flutter/material.dart';

/// Horizontal capsule-chip type selector for marketplace posts.
///
/// Replaces the old DropdownButtonFormField so all types are visible at a
/// glance.  Filters chips by [allowedTypes] when provided.
class PublishTypeSelector extends StatelessWidget {
  final String currentType;
  final List<String>? allowedTypes;
  final ValueChanged<String> onChanged;

  const PublishTypeSelector({
    super.key,
    required this.currentType,
    this.allowedTypes,
    required this.onChanged,
  });

  static const _allTypes = ['sell', 'buy', 'lost', 'found', 'exposure'];

  static const _labels = <String, String>{
    'sell': '出售',
    'buy': '求购',
    'lost': '失物',
    'found': '招领',
    'exposure': '曝光',
  };

  List<String> get _types => allowedTypes == null
      ? _allTypes
      : _allTypes.where((t) => allowedTypes!.contains(t)).toList();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _types.map((type) {
          final selected = type == currentType;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(_labels[type] ?? type),
              selected: selected,
              onSelected: (_) => onChanged(type),
              selectedColor: colorScheme.primary.withValues(alpha: 0.15),
              backgroundColor: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.grey.withValues(alpha: 0.08),
              side: BorderSide(
                color: selected
                    ? colorScheme.primary.withValues(alpha: 0.55)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.grey.withValues(alpha: 0.25)),
              ),
              labelStyle: TextStyle(
                color: selected ? colorScheme.primary : null,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 13,
              ),
              visualDensity: VisualDensity.compact,
            ),
          );
        }).toList(),
      ),
    );
  }
}
