import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('体测匿名统计资产不包含原始隐私字段', () {
    final raw =
        File('assets/data/physical_percentiles.json').readAsStringSync();
    for (final term in ['姓名', '学号', '班级', '院系', '学院号', '专业号', 'student_id']) {
      expect(raw, isNot(contains(term)), reason: '不应包含 $term');
    }
  });
}
