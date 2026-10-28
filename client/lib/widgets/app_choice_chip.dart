import 'package:flutter/material.dart';
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
    if (context.watch<ThemeProvider?>()?.frostedGlass != true) {
      return ChoiceChip(
          avatar: avatar,
          label: label,
          labelStyle: labelStyle,
          labelPadding: labelPadding,
          onSelected: onSelected,
          pressElevation: pressElevation,
          selected: selected,
          selectedColor: selectedColor,
          disabledColor: disabledColor,
          tooltip: tooltip,
          side: side,
          shape: shape,
          clipBehavior: clipBehavior,
          focusNode: focusNode,
          autofocus: autofocus,
          color: color,
          backgroundColor: backgroundColor,
          padding: padding,
          visualDensity: visualDensity,
          materialTapTargetSize: materialTapTargetSize,
          elevation: elevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          iconTheme: iconTheme,
          selectedShadowColor: selectedShadowColor,
          showCheckmark: showCheckmark,
          checkmarkColor: checkmarkColor,
          avatarBorder: avatarBorder,
          avatarBoxConstraints: avatarBoxConstraints,
          chipAnimationStyle: chipAnimationStyle,
          mouseCursor: mouseCursor);
    }
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
    final chipShape = shape ?? theme.chipTheme.shape;
    final radius = chipShape is RoundedRectangleBorder
        ? chipShape.borderRadius
        : chipShape is StadiumBorder
            ? BorderRadius.circular(AppRadius.pill)
            : BorderRadius.circular(AppRadius.sm);
    return Theme(
      // RawChip 内部 Material 未显式指定底色，会使用 canvasColor。
      // 必须清除此底色，否则它会盖住外层玻璃及选中颜色。
      data: theme.copyWith(canvasColor: Colors.transparent),
      child: AppCardSurface(
        decoration: BoxDecoration(color: surface, borderRadius: radius),
        child: ChoiceChip(
          avatar: avatar,
          label: label,
          labelStyle: labelStyle,
          labelPadding: labelPadding,
          onSelected: onSelected,
          selected: selected,
          tooltip: tooltip,
          shape: shape,
          side: selected ? side ?? BorderSide.none : BorderSide.none,
          clipBehavior: clipBehavior,
          focusNode: focusNode,
          autofocus: autofocus,
          color: const WidgetStatePropertyAll(Colors.transparent),
          padding: padding,
          visualDensity: visualDensity,
          materialTapTargetSize: materialTapTargetSize,
          elevation: 0,
          pressElevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          iconTheme: iconTheme,
          showCheckmark: showCheckmark,
          checkmarkColor: checkmarkColor,
          avatarBorder: avatarBorder,
          avatarBoxConstraints: avatarBoxConstraints,
          chipAnimationStyle: chipAnimationStyle,
          mouseCursor: mouseCursor,
        ),
      ),
    );
  }
}
