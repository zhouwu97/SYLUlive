import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('体测页报告入口文案为查看超越了多少大学生', () {
    final source =
        File('lib/screens/physical_test_screen.dart').readAsStringSync();
    expect(source, contains('查看超越了多少大学生'));
    expect(source, isNot(contains('查看超越报告')));
  });
}
