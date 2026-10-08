import 'package:flutter/material.dart';

import '../utils/responsive_util.dart';

/// 保留父级视口和背景，仅约束可阅读／操作内容的宽度。
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    this.maxWidth = ResponsiveUtil.readingContentWidth,
    required this.child,
  });

  const ResponsiveContent.form({super.key, required this.child})
      : maxWidth = ResponsiveUtil.formContentWidth;

  const ResponsiveContent.page({super.key, required this.child})
      : maxWidth = ResponsiveUtil.pageContentWidth;

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}
