import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_radius.dart';
import 'app_card.dart';

/// 筛选芯片使用同一卡片材质；保留选中、禁用、焦点和原有点击区域。
class AppChoiceChip extends ChoiceChip {
  const AppChoiceChip({
    super.key,
    super.avatar,
    required super.label,
    super.labelStyle,
    super.labelPadding,
    super.onSelected,
    super.pressElevation,
    required super.selected,
    super.selectedColor,
    super.disabledColor,
    super.tooltip,
    super.side,
    super.shape,
    super.clipBehavior,
    super.focusNode,
    super.autofocus,
    super.color,
    super.backgroundColor,
    super.padding,
    super.visualDensity,
    super.materialTapTargetSize,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.iconTheme,
    super.selectedShadowColor,
    super.showCheckmark,
    super.checkmarkColor,
    super.avatarBorder,
    super.avatarBoxConstraints,
    super.chipAnimationStyle,
    super.mouseCursor,
  });

  @override
  Widget build(BuildContext context) {
    final glass = context.watch<ThemeProvider?>()?.frostedGlass == true;
    final theme = Theme.of(context);
    final states = <WidgetState>{
      if (selected) WidgetState.selected,
      if (onSelected == null) WidgetState.disabled
    };
    final surface = color?.resolve(states) ??
        (onSelected == null ? disabledColor : null) ??
        (selected
            ? selectedColor ??
                theme.chipTheme.selectedColor ??
                theme.colorScheme.secondaryContainer
            : backgroundColor ??
                theme.chipTheme.backgroundColor ??
                theme.colorScheme.surface);
    final chipShape = WidgetStateProperty.resolveAs<OutlinedBorder?>(
            shape ?? theme.chipTheme.shape, states) ??
        (theme.useMaterial3
            ? const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(AppRadius.sm)))
            : const StadiumBorder());
    final originalSide = WidgetStateProperty.resolveAs<BorderSide?>(
            side ?? theme.chipTheme.side, states) ??
        (chipShape.side != BorderSide.none
            ? chipShape.side
            : theme.useMaterial3 && !selected
                ? const BorderSide()
                : BorderSide.none);
    final density = (visualDensity ?? theme.visualDensity).baseSizeAdjustment;
    final padded = (materialTapTargetSize ?? theme.materialTapTargetSize) ==
        MaterialTapTargetSize.padded;
    return Theme(
      // RawChip 内部 Material 未显式指定底色，会使用 canvasColor。
      // 必须清除此底色，否则它会盖住外层玻璃及选中颜色。
      data: glass ? theme.copyWith(canvasColor: Colors.transparent) : theme,
      child: _ChipTapTarget(
        constraints: padded
            ? BoxConstraints(
                minWidth: kMinInteractiveDimension + density.dx,
                minHeight: kMinInteractiveDimension + density.dy,
              )
            : const BoxConstraints(),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: chipShape),
            child: AppCardSurface(
              blur: glass ? 10 : 0,
              surfaceOpacity: glass ? null : 1,
              decoration: BoxDecoration(
                  color: glass ? surface : Colors.transparent,
                  borderRadius: BorderRadius.zero),
              child: ChoiceChip(
                avatar: avatar,
                label: label,
                labelStyle: labelStyle,
                labelPadding: labelPadding,
                onSelected: onSelected,
                selected: selected,
                tooltip: tooltip,
                shape: chipShape,
                // 只隐藏描边颜色，保留原生 ShapeDecoration 的边框占位。
                side: !glass || selected
                    ? originalSide
                    : originalSide.copyWith(color: Colors.transparent),
                clipBehavior: clipBehavior,
                focusNode: focusNode,
                autofocus: autofocus,
                color: glass
                    ? const WidgetStatePropertyAll(Colors.transparent)
                    : color,
                selectedColor: selectedColor,
                disabledColor: disabledColor,
                backgroundColor: backgroundColor,
                padding: padding,
                visualDensity: visualDensity,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                elevation: glass ? 0 : elevation,
                pressElevation: glass ? 0 : pressElevation,
                shadowColor: glass ? Colors.transparent : shadowColor,
                selectedShadowColor:
                    glass ? Colors.transparent : selectedShadowColor,
                surfaceTintColor: glass ? Colors.transparent : surfaceTintColor,
                iconTheme: iconTheme,
                showCheckmark: showCheckmark,
                checkmarkColor: checkmarkColor,
                avatarBorder: avatarBorder,
                avatarBoxConstraints: avatarBoxConstraints,
                chipAnimationStyle: chipAnimationStyle,
                mouseCursor: mouseCursor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 沿用原生芯片的触控留白，玻璃仅绘制在内层实际 Material 的范围内。
class _ChipTapTarget extends SingleChildRenderObjectWidget {
  const _ChipTapTarget({required this.constraints, required super.child});
  final BoxConstraints constraints;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChipTapTarget(constraints);

  @override
  void updateRenderObject(
      BuildContext context, _RenderChipTapTarget renderObject) {
    renderObject.additionalConstraints = constraints;
  }
}

class _RenderChipTapTarget extends RenderConstrainedBox {
  _RenderChipTapTarget(BoxConstraints constraints)
      : super(additionalConstraints: constraints);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    if (!size.contains(position)) return false;
    final center = Offset(position.dx, size.height / 2);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(center),
      position: position,
      hitTest: (result, position) => child!.hitTest(result, position: position),
    );
  }
}
