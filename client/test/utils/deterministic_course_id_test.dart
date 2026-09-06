import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/deterministic_course_id.dart';

void main() {
  test('课表 ID 使用跨运行时稳定的 SHA-256 结果', () {
    const name = '高等数学';
    const teacher = '王老师';
    const location = 'A101';
    const courseCode = 'MATH-101';
    const weekday = 1;
    const startSection = 1;
    const endSection = 2;
    const weeks = [1, 2, 3, 4, 5, 6, 7, 8];
    final canonical = [
      'v1',
      courseCode,
      name,
      teacher,
      location,
      weekday,
      startSection,
      endSection,
      weeks.join(','),
    ].join('\u001f');
    final bytes = sha256.convert(utf8.encode(canonical)).bytes;
    var expected = 0;
    for (final byte in bytes.take(4)) {
      expected = (expected << 8) | byte;
    }
    expected &= 0x7fffffff;
    if (expected == 0) expected = 1;

    expect(
      deterministicCourseId(
        courseCode: courseCode,
        name: name,
        teacher: teacher,
        location: location,
        weekday: weekday,
        startSection: startSection,
        endSection: endSection,
        weeks: weeks,
      ),
      expected,
    );
  });
}
