import 'package:flutter/material.dart';

/// 底栏与侧栏共用的悬浮轨道，始终为图标和文字保留正常朝向。
class NavigationDockLayout extends StatelessWidget {
  const NavigationDockLayout({
    super.key,
    required this.axis,
    required this.child,
  });

  static const sideWidth = 112.0;
  final Axis axis;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final vertical = axis == Axis.vertical;
    return SafeArea(
      top: vertical,
      right: !vertical,
      minimum: vertical
          ? const EdgeInsets.symmetric(vertical: 16)
          : const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 16)
            : const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Align(
          alignment: vertical ? Alignment.centerLeft : Alignment.center,
          widthFactor: vertical ? 1 : null,
          heightFactor: vertical ? null : 1,
          child: ConstrainedBox(
            constraints: vertical
                ? const BoxConstraints(maxHeight: 440)
                : const BoxConstraints(maxWidth: 440),
            child: SizedBox(
              width: vertical ? 80 : double.infinity,
              height: vertical ? double.infinity : 64,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
