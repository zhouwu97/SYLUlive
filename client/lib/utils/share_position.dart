import 'package:flutter/widgets.dart';

/// iPad 的系统分享面板需要位于当前窗口内的非空锚点。
Rect? sharePosition(BuildContext context) {
  if (!context.mounted) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final view = Offset.zero & MediaQuery.sizeOf(context);
  final bounds = (box.localToGlobal(Offset.zero) & box.size).intersect(view);
  if (!bounds.isEmpty) return bounds;
  return Rect.fromCenter(center: view.center, width: 1, height: 1);
}
