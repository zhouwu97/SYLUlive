import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 集市发布类型选择器。
class PublishTypeSelector extends StatelessWidget {
  static const _accent = Color(0xFF4F5AF7);

  final String currentType;
  final List<String>? allowedTypes;
  final ValueChanged<String> onChanged;

  const PublishTypeSelector({
    super.key,
    required this.currentType,
    this.allowedTypes,
    required this.onChanged,
  });

  static const _allTypes = ['sell', 'buy', 'lost', 'found', 'proxy'];

  static const _labels = <String, String>{
    'sell': '出售',
    'buy': '求购',
    'lost': '失物',
    'found': '招领',
    'proxy': '办事',
  };

  List<String> get _types => allowedTypes == null
      ? _allTypes
      : _allTypes.where((type) => allowedTypes!.contains(type)).toList();

  Future<void> _showPicker(BuildContext context) async {
    final types = _types;
    if (types.isEmpty) return;

    var selectedIndex = types.indexOf(currentType);
    if (selectedIndex < 0) selectedIndex = 0;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return SafeArea(
          top: false,
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF171B24) : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(
                          '取消',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                      const Spacer(),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        onPressed: () {
                          onChanged(types[selectedIndex]);
                          Navigator.of(context).pop();
                        },
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 216,
                  child: CupertinoPicker(
                    scrollController:
                        FixedExtentScrollController(initialItem: selectedIndex),
                    itemExtent: 44,
                    magnification: 1.08,
                    squeeze: 1.08,
                    useMagnifier: true,
                    onSelectedItemChanged: (index) => selectedIndex = index,
                    children: [
                      for (final type in types)
                        Center(
                          child: Text(
                            _labels[type] ?? type,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentLabel = _labels[currentType] ?? '请选择';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showPicker(context),
        child: Container(
          constraints: const BoxConstraints(minWidth: 112, minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFF2F3F7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : colorScheme.outlineVariant.withValues(alpha: 0.55),
            ),
            boxShadow: [
              if (!isDark)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  currentLabel,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: currentType.isEmpty
                        ? colorScheme.onSurfaceVariant
                        : _accent,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 21,
                color: currentType.isEmpty
                    ? colorScheme.onSurfaceVariant
                    : const Color(0xFF555B6B),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
