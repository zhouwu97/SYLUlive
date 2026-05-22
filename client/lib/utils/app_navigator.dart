import 'package:flutter/material.dart';

/// 全局导航 Key，用于在 Dio 拦截器等无 BuildContext 的地方执行导航
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 桌面小组件点击 → 通知 HomeScreen 切到课程表 tab
final ValueNotifier<int> widgetTabSwitch = ValueNotifier<int>(0);
