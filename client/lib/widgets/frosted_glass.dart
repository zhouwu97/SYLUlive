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
    final useFrostedGlass =
        enabled ?? context.watch<ThemeProvider?>()?.frostedGlass ?? false;
    if (!useFrostedGlass || sigmaX <= 0 || sigmaY <= 0) return child;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY),
      // 弹层淡入和滚动合成可能创建 saveLayer；srcOver 会再叠一次
      // 已过滤的底面，留下重影。只替换滤镜底面，不改变前景文字透明度。
      blendMode: BlendMode.src,
      child: child,
    );
  }
}
