import 'package:flutter/material.dart';

/// 全局导航 Key，用于在 Dio 拦截器等无 BuildContext 的地方执行导航
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 页面可见性观察器，用于避免被图片查看器等路由覆盖时误标私信已读。
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// 全局 ScaffoldMessenger Key，用于在无 BuildContext 的地方显示 SnackBar
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 桌面小组件点击 → 通知 HomeScreen 切到课程表 tab
final ValueNotifier<int> widgetTabSwitch = ValueNotifier<int>(0);

/// HomeScreen 当前已提交的 root tab 索引。
///
/// 供深层页面（私信/帖子/通知）在被推入时记录底层根 tab，作为
/// `lastPage` 深层恢复时打底的根 tab。
final ValueNotifier<int> currentHomeTabIndex = ValueNotifier<int>(0);

int _lastWidgetTabSwitchValue = 0;

/// 消耗小组件 tab 切换事件，如果自上次消耗后发生过更新则返回 true
bool consumeWidgetTabSwitch() {
  if (widgetTabSwitch.value > _lastWidgetTabSwitchValue) {
    _lastWidgetTabSwitchValue = widgetTabSwitch.value;
    return true;
  }
  return false;
}
