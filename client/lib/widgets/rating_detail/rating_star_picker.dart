import 'package:flutter/material.dart';

/// 可复用的星级选择器。
///
/// 从既有评分输入中抽出，供教师详情评分与课程评价表单共用，
/// 两者的视觉表现与交互行为保持一致。
///
/// 无障碍：每颗星都有独立语义标签（"1 星"…"5 星"），
/// 命中区不小于 44×44，满足触控与读屏要求。
class RatingStarPicker extends StatelessWidget {
  /// 当前星级，0 表示未选择。
  final int value;

  /// 选中某颗星时回调，值为 1–5。
  final ValueChanged<int> onChanged;

  final double iconSize;
  final Color? activeColor;
  final Color? inactiveColor;
  final bool enabled;

  /// 最小命中区边长，对齐平台触控规范。
  static const double minHitSize = 44;

  const RatingStarPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.iconSize = 40,
    this.activeColor,
    this.inactiveColor,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final active = activeColor ?? Colors.amber;
    final inactive = inactiveColor ?? Colors.grey[400] ?? Colors.grey;
    final hitSize = (iconSize + 8) < minHitSize ? minHitSize : iconSize + 8;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        final star = index + 1;
        final selected = index < value;
        return Semantics(
          label: '$star 星',
          selected: selected,
          button: true,
          enabled: enabled,
          child: InkWell(
            onTap: enabled ? () => onChanged(star) : null,
            borderRadius: BorderRadius.circular(hitSize / 2),
            child: SizedBox(
              width: hitSize,
              height: hitSize,
              child: Center(
                child: Icon(
                  selected ? Icons.star : Icons.star_border,
                  size: iconSize,
                  color: selected ? active : inactive,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
