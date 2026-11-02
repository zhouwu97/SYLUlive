import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';

/// 卡片和弹层的毛玻璃门控，与壁纸模糊和液态底栏设置相互独立。
class FrostedGlass extends StatelessWidget {
  final Widget child;
  final double sigmaX;
  final double sigmaY;
  final bool? enabled;

  const FrostedGlass({
    super.key,
    required this.child,
    this.sigmaX = 10,
    this.sigmaY = 10,
    this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final appearance = context.select<ThemeProvider?, (bool, double)>(
      (theme) {
        final active = (enabled ?? theme?.frostedGlass ?? false) &&
            (theme == null || theme.shouldShowCustomBackground) &&
            sigmaX > 0 &&
            sigmaY > 0;
        return (active, active ? theme?.frostedGlassStrength ?? 1 : 0);
      },
    );
    final useFrostedGlass = appearance.$1;
    final strength = appearance.$2;
    return BackdropFilter(
      // 开关与 0% 都只禁用渲染层，不重建页面、滚动、焦点或异步内容。
      enabled: useFrostedGlass && strength > 0 && sigmaX > 0 && sigmaY > 0,
      filter: ImageFilter.blur(
        sigmaX: sigmaX * strength,
        sigmaY: sigmaY * strength,
      ),
      // 弹层淡入和滚动合成可能创建 saveLayer；srcOver 会再叠一次
      // 已过滤的底面，留下重影。只替换滤镜底面，不改变前景文字透明度。
      blendMode: BlendMode.src,
      child: child,
    );
  }
}
