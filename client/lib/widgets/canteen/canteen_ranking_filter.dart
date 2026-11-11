import '../app_card.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../models/canteen_ranking.dart';
import '../../providers/canteen_provider.dart';
import 'canteen_theme.dart';

/// 排行页位置筛选可选值：'' 表示该维度不限。
// 位置选项来自服务端 /canteens/meta（加载失败时为内置默认值）；'' 表示“全部”。
// 独立使用该组件（如组件测试）时没有 CanteenProvider，直接用默认值。
List<String> _areaOptions(BuildContext context) => [
      '',
      ...(context.watch<CanteenProvider?>()?.locationAreas ??
          CanteenProvider.defaultLocationAreas),
    ];
List<String> _floorOptions(BuildContext context) => [
      '',
      ...(context.watch<CanteenProvider?>()?.locationFloors ??
          CanteenProvider.defaultLocationFloors),
    ];

/// 筛选条按钮文案：两个维度都为空时显示中性「位置」。
String canteenLocationFilterLabel(String area, String floor) {
  final parts = [
    if (area.isNotEmpty) area,
    if (floor.isNotEmpty) floor,
  ];
  return parts.isEmpty ? '位置' : parts.join('·');
}

/// 组合筛选：区域与楼层同时命中（只设一个维度时该维度单独生效）。
bool canteenRankingItemMatchesLocation(
  CanteenRankingItem item,
  String area,
  String floor,
) {
  if (area.isNotEmpty && item.locationArea != area) return false;
  if (floor.isNotEmpty && item.locationFloor != floor) return false;
  return true;
}

/// 排行页排序筛选条：综合 / 评分 / 评价人数 + 位置筛选小按钮。
/// 热度待热度表上线后再开放，不在无真实数据时提供假的热度排序。
class CanteenRankingFilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;
  final String locationArea;
  final String locationFloor;
  final void Function(String area, String floor) onLocationFilterChanged;

  const CanteenRankingFilterBar({
    super.key,
    required this.selected,
    required this.onChanged,
    this.locationArea = '',
    this.locationFloor = '',
    required this.onLocationFilterChanged,
    this.tagKey = '',
    this.onTagChanged,
  });

  /// 当前标签筛选（'' = 不限）；[onTagChanged] 为空时不显示标签筛选。
  final String tagKey;
  final ValueChanged<String>? onTagChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _sortChip(isDark, '综合排序', CanteenRankingSort.composite),
          const SizedBox(width: 8),
          // 服务端 rating 排序刻意从低分往高分排，用于先看到踩雷反馈；
          // 文案必须说清方向，不能写成会被理解为“高分在前”的“评分优先”。
          _sortChip(isDark, '低分优先', CanteenRankingSort.rating),
          const SizedBox(width: 8),
          _sortChip(isDark, '评价人数', CanteenRankingSort.reviewCount),
          const SizedBox(width: 8),
          _locationChip(context, isDark),
          if (onTagChanged != null) ...[
            const SizedBox(width: 8),
            _tagChip(context, isDark),
          ],
        ],
      ),
    );
  }

  Widget _sortChip(bool isDark, String label, String value) {
    return _pill(
      isDark,
      label: label,
      selected: selected == value,
      onTap: () => onChanged(value),
    );
  }

  Widget _locationChip(BuildContext context, bool isDark) {
    final isSel = locationArea.isNotEmpty || locationFloor.isNotEmpty;
    return _pill(
      isDark,
      label: canteenLocationFilterLabel(locationArea, locationFloor),
      selected: isSel,
      leading: Icon(
        Icons.filter_list_rounded,
        size: 15,
        color: isSel
            ? CanteenTheme.accentStrongColor(isDark)
            : CanteenTheme.textSecondaryColor(isDark),
      ),
      onTap: () => _showLocationSheet(context, isDark),
    );
  }

  Widget _tagChip(BuildContext context, bool isDark) {
    final tags = context.watch<CanteenProvider?>()?.reviewTags ??
        CanteenProvider.defaultReviewTags;
    final selectedLabel = tags
            .where((tag) => tag.key == tagKey)
            .map((tag) => tag.label)
            .firstOrNull ??
        '';
    final isSel = selectedLabel.isNotEmpty;
    return _pill(
      isDark,
      label: isSel ? selectedLabel : '标签',
      selected: isSel,
      leading: Icon(
        Icons.sell_outlined,
        size: 15,
        color: isSel
            ? CanteenTheme.accentStrongColor(isDark)
            : CanteenTheme.textSecondaryColor(isDark),
      ),
      onTap: () => _showTagSheet(context, isDark, tags),
    );
  }

  void _showTagSheet(BuildContext context, bool isDark,
      List<({String key, String label})> tags) {
    context.read<CanteenProvider?>()?.loadMeta();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AppCardSurface(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: CanteenTheme.surfaceBg(isDark),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '按同学评价标签筛选',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '只看近 30 天常被这样评价的商家',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in [(key: '', label: '全部'), ...tags])
                    ChoiceChip(
                      label: Text(tag.label),
                      selected: tag.key == tagKey,
                      onSelected: (_) {
                        Navigator.pop(sheetContext);
                        onTagChanged?.call(tag.key);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(
    bool isDark, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Icon? leading,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AppCardSurface(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? CanteenTheme.accentSoftColor(isDark)
              : CanteenTheme.surfaceBg(isDark),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? CanteenTheme.accentColor(isDark)
                : CanteenTheme.borderColor(isDark),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              leading,
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? CanteenTheme.accentStrongColor(isDark)
                    : CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLocationSheet(BuildContext context, bool isDark) {
    context.read<CanteenProvider?>()?.loadMeta();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _LocationFilterSheet(
          isDark: isDark,
          initialArea: locationArea,
          initialFloor: locationFloor,
          onApplied: onLocationFilterChanged,
        );
      },
    );
  }
}

/// 位置筛选弹层：区域 + 楼层两组胶囊，组合生效，点「应用」后关闭。
class _LocationFilterSheet extends StatefulWidget {
  final bool isDark;
  final String initialArea;
  final String initialFloor;
  final void Function(String area, String floor) onApplied;

  const _LocationFilterSheet({
    required this.isDark,
    required this.initialArea,
    required this.initialFloor,
    required this.onApplied,
  });

  @override
  State<_LocationFilterSheet> createState() => _LocationFilterSheetState();
}

class _LocationFilterSheetState extends State<_LocationFilterSheet> {
  late String _area = widget.initialArea;
  late String _floor = widget.initialFloor;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return AppCardSurface(
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '按位置筛选',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: CanteenTheme.textPrimaryColor(isDark),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '组合选择食堂区域与楼层，如「一食堂 + 一楼」',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
            const SizedBox(height: 14),
            _groupLabel(isDark, '区域'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in _areaOptions(context))
                  _optionChip(isDark, '区域', option),
              ],
            ),
            const SizedBox(height: 14),
            _groupLabel(isDark, '楼层'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in _floorOptions(context))
                  _optionChip(isDark, '楼层', option),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      widget.onApplied('', '');
                      Navigator.pop(context);
                    },
                    child: Text(
                      '重置',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () {
                      widget.onApplied(_area, _floor);
                      Navigator.pop(context);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: CanteenTheme.accentColor(isDark),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(
                      _applyButtonLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String get _applyButtonLabel {
    final label = canteenLocationFilterLabel(_area, _floor);
    return label == '位置' ? '查看全部商家' : '看$label';
  }

  Widget _groupLabel(bool isDark, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: CanteenTheme.textSecondaryColor(isDark),
      ),
    );
  }

  Widget _optionChip(bool isDark, String group, String option) {
    final selected = group == '区域' ? _area == option : _floor == option;
    final label = option.isEmpty ? '全部' : option;
    return GestureDetector(
      onTap: () => setState(() {
        if (group == '区域') {
          _area = option;
        } else {
          _floor = option;
        }
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? CanteenTheme.accentSoftColor(isDark)
              : CanteenTheme.surfaceMutedBg(isDark),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? CanteenTheme.accentColor(isDark)
                : CanteenTheme.borderColor(isDark),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(
                Icons.check_rounded,
                size: 15,
                color: CanteenTheme.accentStrongColor(isDark),
              ),
              const SizedBox(width: 3),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? CanteenTheme.accentStrongColor(isDark)
                    : CanteenTheme.textPrimaryColor(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
