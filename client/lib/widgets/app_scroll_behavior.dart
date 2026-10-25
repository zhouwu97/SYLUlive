import 'package:flutter/material.dart';

/// 边缘拉伸的离屏层会隔断 BackdropFilter 对壁纸的采样。
/// 在应用入口统一门控，覆盖普通路由、侧栏和弹层中的滚动视图。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior({required this.frostedGlass});

  final bool frostedGlass;

  @override
  bool shouldNotify(covariant AppScrollBehavior oldDelegate) =>
      frostedGlass != oldDelegate.frostedGlass;

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      frostedGlass
          ? child
          : super.buildOverscrollIndicator(context, child, details);
}
