import 'package:flutter/material.dart';

class ResponsiveUtil {
  // 断点定义
  static const double mobileMaxWidth = 600;
  static const double tabletMaxWidth = 840;

  /// 是否为手机屏幕（窄屏）
  static bool isMobile(BuildContext context) {
    return MediaQuery.of(context).size.width < mobileMaxWidth;
  }

  /// 是否为平板屏幕（横屏或竖屏）
  static bool isTablet(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= mobileMaxWidth && width < tabletMaxWidth;
  }

  /// 是否为宽屏平板或桌面端（支持双栏等更复杂的布局）
  static bool isDesktop(BuildContext context) {
    return MediaQuery.of(context).size.width >= tabletMaxWidth;
  }

  /// 获取当前屏幕类型对应的最佳内容最大宽度
  static double getMaxContentWidth(BuildContext context) {
    if (isDesktop(context)) {
      return 1200;
    } else if (isTablet(context)) {
      return 800;
    } else {
      return double.infinity;
    }
  }
}
