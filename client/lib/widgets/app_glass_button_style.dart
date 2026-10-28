import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import 'app_card.dart';

/// 材质绘制在原生按钮内部，保留其命中范围、键盘、状态和 Ink 行为。
/// 只让底面透明；文字与图标使用实色，避免玻璃底色变浅后白字难辨。
ButtonStyle appGlassButtonStyle(BuildContext context, ButtonStyle style,
    {Color? fallbackBackground}) {
  final appearance = context.watch<ThemeProvider?>();
  if (appearance?.frostedGlass != true) return style;
  final theme = Theme.of(context);
  Color surface(Set<WidgetState> states) =>
      style.backgroundColor?.resolve(states) ??
      fallbackBackground ??
      theme.colorScheme.surface;
  Color foreground(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) {
      return style.foregroundColor?.resolve(states) ??
          theme.colorScheme.onSurface.withValues(alpha: .38);
    }
    final alpha = appearance!.shouldShowCustomBackground
        ? appearance.componentOpacity
        : 1.0;
    final composited = Color.alphaBlend(
        appGlassSurfaceColor(context, surface(states), alpha),
        theme.colorScheme.surface);
    return composited.computeLuminance() > .179 ? Colors.black : Colors.white;
  }

  return style.copyWith(
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith(foreground),
    iconColor: WidgetStateProperty.resolveWith(foreground),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    backgroundBuilder: (context, states, child) => ClipPath(
      // 部分按钮显式使用 Clip.none；滤镜必须自行遵守原按钮形状，
      // 不能依赖上层 Material 的裁剪，否则会露出矩形底面。
      clipper: ShapeBorderClipper(shape: style.shape?.resolve(states) ??
          const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)))),
      child: AppCardSurface(
        decoration: BoxDecoration(
          color: surface(states),
          borderRadius: BorderRadius.zero,
        ),
        child: child,
      ),
    ),
  );
}
