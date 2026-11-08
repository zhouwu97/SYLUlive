import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 关闭材质时保留 Widget 子树，但不提交模糊层；检查实际启用的滤镜。
Finder activeBackdropFilters() => find.byWidgetPredicate(
    (widget) => widget is BackdropFilter && widget.enabled,
    description: 'enabled BackdropFilter');
