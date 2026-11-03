import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import 'frosted_glass.dart';

/// 卡片及系统弹层共用的最终底色，透明度只应用一次。
Color appGlassSurfaceColor(BuildContext context, Color? color, double opacity) {
  final base = Theme.of(context).brightness == Brightness.dark
      ? AppColors.surfaceSecondaryDark
      : AppColors.surfaceSecondaryLight;
  // 语义色的浅色底（如 warning.withValues(alpha: .08)）仍保持原来的色调，
  // 仅把最终卡片底面的透明度交给全局设置。
  return Color.alphaBlend(color ?? base, base).withValues(alpha: opacity);
}

/// 壁纸上的说明文字使用实色语义前景，简洁模式保留原配色。
Color appContentSecondaryColor(BuildContext context, Color fallback) =>
    context.watch<ThemeProvider?>()?.shouldShowCustomBackground == true
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : fallback;

Gradient _glassGradient(
    BuildContext context, Gradient gradient, double opacity) {
  // 先合成原本的淡色，再应用组件不透明度；直接 withOpacity 会把
  // 8% 的语义渐变变成 70%／100% 饱和色，深色及简洁模式尤为明显。
  final colors = gradient.colors
      .map((color) => appGlassSurfaceColor(context, color, opacity))
      .toList(growable: false);
  if (gradient is LinearGradient) {
    return LinearGradient(
      begin: gradient.begin,
      end: gradient.end,
      colors: colors,
      stops: gradient.stops,
      tileMode: gradient.tileMode,
      transform: gradient.transform,
    );
  }
  if (gradient is RadialGradient) {
    return RadialGradient(
      center: gradient.center,
      radius: gradient.radius,
      colors: colors,
      stops: gradient.stops,
      tileMode: gradient.tileMode,
      focal: gradient.focal,
      focalRadius: gradient.focalRadius,
      transform: gradient.transform,
    );
  }
  if (gradient is SweepGradient) {
    return SweepGradient(
      center: gradient.center,
      startAngle: gradient.startAngle,
      endAngle: gradient.endAngle,
      colors: colors,
      stops: gradient.stops,
      tileMode: gradient.tileMode,
      transform: gradient.transform,
    );
  }
  return gradient.scale(opacity);
}

/// 菜单／设置组内部的装饰分隔线，玻璃模式只保留原有行间距。
class AppCardDivider extends Divider {
  const AppCardDivider({
    super.key,
    super.height,
    super.thickness,
    super.indent,
    super.endIndent,
    super.color,
  });

  @override
  Widget build(BuildContext context) {
    if (context.watch<ThemeProvider?>()?.frostedGlass == true) {
      return SizedBox(height: height ?? DividerTheme.of(context).space ?? 16);
    }
    return super.build(context);
  }
}

/// 为正文、说明和状态内容提供底面，已有卡片内不重复绘制。
/// 页面和分组标题保持透明；文字是否需要承托按用途判断，不按长短判断。
class AppContentSurface extends StatelessWidget {
  const AppContentSurface({super.key, required this.child})
      : _reading = false,
        _cardRadius = null;

  /// 独立说明使用圆角底面，利用已有周边留白绘制，不改变文字布局。
  const AppContentSurface.reading({super.key, required this.child})
      : _reading = true,
        _cardRadius = null;

  /// 独立内容与状态卡使用统一圆角，保留原有子树和布局留白。
  const AppContentSurface.card({super.key, required this.child})
      : _reading = false,
        _cardRadius = AppRadius.lg;

  final Widget child;
  final bool _reading;
  final double? _cardRadius;

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<ThemeProvider?>();
    final insideSurface =
        context.findAncestorWidgetOfExactType<AppContentSurface>() != null ||
        context.findAncestorWidgetOfExactType<AppCardSurface>() != null ||
            context.findAncestorWidgetOfExactType<AppCardMaterial>() != null ||
            context.findAncestorWidgetOfExactType<AppCard>() != null;
    final paint =
        appearance?.shouldShowCustomBackground == true && !insideSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color =
        dark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight;
    if (_reading) {
      // 背景与前景分开绘制：圆角不会裁切首尾文字，开关也不改变内容宽度。
      return Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            left: -AppSpacing.sm,
            right: -AppSpacing.sm,
            top: -AppSpacing.xs,
            bottom: -AppSpacing.xs,
            child: IgnorePointer(
              child: AppCardSurface(
                blur: paint ? 10 : 0,
                surfaceOpacity: paint ? null : 0,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          child,
        ],
      );
    }
    // 固定子树；简洁模式和已存在的卡片只关闭本层绘制，不重建内容。
    return AppCardSurface(
      blur: paint ? 10 : 0,
      surfaceOpacity: paint ? null : 0,
      color: _cardRadius == null ? color : null,
      decoration: _cardRadius == null
          ? null
          : BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(_cardRadius!),
            ),
      child: child,
    );
  }
}

/// 所有内容卡片共用的材质。模糊开关与底面不透明度分别控制。
///
/// 卡片只模糊背后的内容；文字、图标、封面和点击区域仍按原样绘制。
class AppCardSurface extends Container {
  final double blur;

  /// 课表等已有独立透明度设置的表面保留自己的设置。
  final double? surfaceOpacity;
  AppCardSurface({
    super.key,
    super.alignment,
    super.padding,
    super.color,
    super.decoration,
    super.foregroundDecoration,
    super.width,
    super.height,
    super.constraints,
    super.margin,
    super.transform,
    super.transformAlignment,
    super.child,
    super.clipBehavior,
    this.blur = 10,
    this.surfaceOpacity,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeProvider?>();
    final glass = settings?.frostedGlass == true && blur > 0;
    final custom = settings?.shouldShowCustomBackground == true;
    final box =
        decoration is BoxDecoration ? decoration! as BoxDecoration : null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = color ??
        box?.color ??
        (dark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    final alpha = surfaceOpacity ??
        (settings?.shouldShowCustomBackground == true
            ? settings!.componentOpacity
            : 1.0);
    final radius = box?.borderRadius ?? BorderRadius.zero;
    final plain = box == null
        ? BoxDecoration(color: surface)
        : box.color == null && box.gradient == null
            ? box.copyWith(color: surface)
            : box;
    final shape = box?.shape == BoxShape.circle
        ? const CircleBorder()
        : RoundedRectangleBorder(borderRadius: radius);
    final material = glass
        ? BoxDecoration(
            color: box?.gradient == null
                ? appGlassSurfaceColor(context, surface, alpha)
                : null,
            gradient: box?.gradient == null
                ? null
                : _glassGradient(context, box!.gradient!, alpha),
            image: box?.image,
            borderRadius: box?.shape == BoxShape.circle ? null : radius,
            shape: box?.shape ?? BoxShape.rectangle,
          )
        : plain.copyWith(
            color: plain.gradient != null
                ? plain.color
                : custom && plain.color?.a != 0
                    ? appGlassSurfaceColor(context, plain.color, alpha)
                    : alpha == 1
                        ? plain.color
                        : plain.color
                            ?.withValues(alpha: plain.color!.a * alpha),
            gradient: plain.gradient == null
                ? null
                : custom
                    ? _glassGradient(context, plain.gradient!, alpha)
                    : alpha == 1
                        ? plain.gradient
                        : plain.gradient?.scale(alpha),
          );
    return Container(
      margin: margin,
      constraints: constraints,
      transform: transform,
      transformAlignment: transformAlignment,
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: FrostedGlass(
          enabled: glass,
          sigmaX: blur,
          sigmaY: blur,
          // 材质只替换绘制，保留原 Container 的边框占位和显式内容间距。
          child: DecoratedBox(
            decoration: material,
            child: Container(
              alignment: alignment,
              padding: decoration?.padding == null
                  ? padding
                  : decoration!.padding.add(padding ?? EdgeInsets.zero),
              foregroundDecoration: foregroundDecoration,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Material Card 的统一入口，保留原有语义、形状、边距和 Ink 响应。
class AppCard extends Card {
  /// 仅保留表示选中、警告等状态的边框，普通装饰描边统一隐藏。
  final bool preserveBorder;
  const AppCard({
    super.key,
    super.color,
    super.shadowColor,
    super.surfaceTintColor,
    super.elevation,
    super.shape,
    super.borderOnForeground,
    super.margin,
    super.clipBehavior,
    super.child,
    super.semanticContainer,
    this.preserveBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeProvider?>();
    final glass = settings?.frostedGlass == true;
    final theme = Theme.of(context);
    final cardTheme = CardTheme.of(context);
    final alpha = settings?.shouldShowCustomBackground == true
        ? settings!.componentOpacity
        : 1.0;
    final fill = color ??
        cardTheme.color ??
        (theme.useMaterial3
            ? theme.colorScheme.surfaceContainerLow
            : theme.cardColor);
    final originalShape = shape ??
        cardTheme.shape ??
        RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
                Theme.of(context).useMaterial3 ? AppRadius.md : 4));
    final glassShape =
        glass && !preserveBorder && originalShape is OutlinedBorder
            ? originalShape.copyWith(side: BorderSide.none)
            : originalShape;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = color ??
        cardTheme.color ??
        (dark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    return Padding(
      padding: margin ?? cardTheme.margin ?? const EdgeInsets.all(4),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: glassShape),
        child: FrostedGlass(
          enabled: glass,
          child: Card(
            margin: EdgeInsets.zero,
            color: glass
                ? appGlassSurfaceColor(context, surface, alpha)
                : settings?.shouldShowCustomBackground == true
                    ? appGlassSurfaceColor(context, surface, alpha)
                    : alpha == 1
                        ? color
                        : fill.withValues(alpha: fill.a * alpha),
            shape: glassShape,
            shadowColor: glass ? Colors.transparent : shadowColor,
            surfaceTintColor: glass ? Colors.transparent : surfaceTintColor,
            elevation: glass ? 0 : elevation,
            borderOnForeground: borderOnForeground,
            clipBehavior: clipBehavior ?? Clip.antiAlias,
            semanticContainer: semanticContainer,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 自绘卡片使用 Material 作为根节点时也接入同一材质。
class AppCardMaterial extends Material {
  /// 弹窗转场分别控制底面和模糊，不把背景滤镜放进透明度离屏层。
  final double? surfaceOpacity;
  final double blur;

  const AppCardMaterial({
    super.key,
    super.type,
    super.elevation,
    super.color,
    super.shadowColor,
    super.surfaceTintColor,
    super.textStyle,
    super.borderRadius,
    super.shape,
    super.borderOnForeground,
    super.clipBehavior,
    super.animationDuration,
    super.child,
    this.surfaceOpacity,
    this.blur = 10,
  });

  @override
  State<Material> createState() => _AppCardMaterialState();
}

class _AppCardMaterialState extends State<Material> {
  @override
  Widget build(BuildContext context) {
    final material = widget as AppCardMaterial;
    final settings = context.watch<ThemeProvider?>();
    final glass = settings?.frostedGlass == true;
    final originalShape = widget.shape ??
        (widget.type == MaterialType.circle
            ? const CircleBorder()
            : RoundedRectangleBorder(
                borderRadius: widget.borderRadius ?? BorderRadius.zero,
              ));
    final shape = glass && originalShape is OutlinedBorder
        ? originalShape.copyWith(side: BorderSide.none)
        : originalShape;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = widget.color ??
        (dark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    final alpha = material.surfaceOpacity ??
        (settings?.shouldShowCustomBackground == true
            ? settings!.componentOpacity
            : 1.0);
    final plainColor = widget.color ??
        switch (widget.type) {
          MaterialType.canvas => Theme.of(context).canvasColor,
          MaterialType.card => Theme.of(context).cardColor,
          _ => null,
        };
    final content = Material(
      type: widget.type,
      elevation: glass ? 0 : widget.elevation,
      color: glass
          ? appGlassSurfaceColor(
              context,
              surface,
              material.surfaceOpacity ??
                  (settings!.shouldShowCustomBackground
                      ? settings.componentOpacity
                      : 1))
          : alpha == 1 || widget.type == MaterialType.transparency
              ? settings?.shouldShowCustomBackground == true &&
                      widget.type != MaterialType.transparency
                  ? appGlassSurfaceColor(context, surface, alpha)
                  : widget.color
              : settings?.shouldShowCustomBackground == true
                  ? appGlassSurfaceColor(context, surface, alpha)
                  : plainColor?.withValues(alpha: plainColor.a * alpha),
      shadowColor: widget.shadowColor,
      surfaceTintColor: glass ? Colors.transparent : widget.surfaceTintColor,
      textStyle: widget.textStyle,
      shape: shape,
      borderOnForeground: widget.borderOnForeground,
      clipBehavior: widget.clipBehavior,
      animationDuration: widget.animationDuration,
      child: widget.child,
    );
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: FrostedGlass(
        enabled: glass,
        sigmaX: material.blur,
        sigmaY: material.blur,
        child: content,
      ),
    );
  }
}
