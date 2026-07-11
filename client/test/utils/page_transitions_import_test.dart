import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS 页面过渡构建器显式导入 Cupertino API', () {
    final source = File('lib/utils/page_transitions.dart').readAsStringSync();

    expect(source, contains("package:flutter/cupertino.dart"));
  });
}
