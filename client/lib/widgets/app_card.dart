import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
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

/// 所有内容卡片共用的材质。关闭毛玻璃时保留原来的实色外观和布局。
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
    if (settings?.frostedGlass != true || blur <= 0) {
      return Container(
        alignment: alignment,
        padding: padding,
        color: color,
        decoration: decoration,
        foregroundDecoration: foregroundDecoration,
        constraints: constraints,
        margin: margin,
        transform: transform,
        transformAlignment: transformAlignment,
        clipBehavior: clipBehavior,
        child: child,
      );
    }
    final box =
        decoration is BoxDecoration ? decoration! as BoxDecoration : null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = color ??
        box?.color ??
        (dark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    final alpha = surfaceOpacity ??
        (settings!.shouldShowCustomBackground
            ? settings.componentOpacity
            : 1.0);
    final radius = box?.borderRadius ?? BorderRadius.circular(AppRadius.lg);
    final shape = box?.shape == BoxShape.circle
        ? const CircleBorder()
        : RoundedRectangleBorder(borderRadius: radius);
    final material = BoxDecoration(
      color:
          box?.gradient == null ? appGlassSurfaceColor(context, surface, alpha) : null,
      gradient: box?.gradient == null
          ? null
          : _glassGradient(context, box!.gradient!, alpha),
      image: box?.image,
      borderRadius: box?.shape == BoxShape.circle ? null : radius,
      shape: box?.shape ?? BoxShape.rectangle,
    );
    return Container(
      margin: margin,
      constraints: constraints,
      transform: transform,
      transformAlignment: transformAlignment,
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: FrostedGlass(
          enabled: true,
          sigmaX: blur,
          sigmaY: blur,
          child: Container(
            alignment: alignment,
            // 装饰描边已移除，不再保留它隐含的 inset；否则封面周围
            // 仍会露出一圈卡片底色。调用者的显式内容间距保持不变。
            padding: padding,
            decoration: material,
            foregroundDecoration: foregroundDecoration,
            child: child,
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
    if (settings?.frostedGlass != true) {
      return Card(
        color: color,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        elevation: elevation,
        shape: shape,
        borderOnForeground: borderOnForeground,
        margin: margin,
        clipBehavior: clipBehavior,
        semanticContainer: semanticContainer,
        child: child,
      );
    }
    final cardTheme = CardTheme.of(context);
    final originalShape = shape ??
        cardTheme.shape ??
        const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)));
    final glassShape = !preserveBorder && originalShape is OutlinedBorder
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
          enabled: true,
          child: Material(
            color: appGlassSurfaceColor(
                context,
                surface,
                settings!.shouldShowCustomBackground
                    ? settings.componentOpacity
                    : 1),
            shape: glassShape,
            child: Semantics(
              container: semanticContainer,
              explicitChildNodes: !semanticContainer,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘卡片使用 Material 作为根节点时也接入同一材质。
class AppCardMaterial extends Material {
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
  });

  @override
  State<Material> createState() => _AppCardMaterialState();
}

class _AppCardMaterialState extends State<Material> {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeProvider?>();
    final glass = settings?.frostedGlass == true;
    final originalShape = widget.shape ??
        RoundedRectangleBorder(
          borderRadius:
              widget.borderRadius ?? BorderRadius.circular(AppRadius.lg),
        );
    final shape = glass && originalShape is OutlinedBorder
        ? originalShape.copyWith(side: BorderSide.none)
        : originalShape;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = widget.color ??
        (dark
            ? AppColors.surfaceSecondaryDark
            : AppColors.surfaceSecondaryLight);
    final content = Material(
      type: widget.type,
      elevation: glass ? 0 : widget.elevation,
      color: glass
          ? appGlassSurfaceColor(
              context,
              surface,
              settings!.shouldShowCustomBackground
                  ? settings.componentOpacity
                  : 1)
          : widget.color,
      shadowColor: widget.shadowColor,
      surfaceTintColor: glass ? Colors.transparent : widget.surfaceTintColor,
      textStyle: widget.textStyle,
      shape: glass ? shape : widget.shape,
      borderRadius: glass ? null : widget.borderRadius,
      borderOnForeground: widget.borderOnForeground,
      clipBehavior: widget.clipBehavior,
      animationDuration: widget.animationDuration,
      child: widget.child,
    );
    if (!glass) return content;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: FrostedGlass(enabled: true, child: content),
    );
  }
}
