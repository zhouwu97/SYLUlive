import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 生成可跨 Dart/Flutter 运行时复用的正整数哈希。
///
/// 这里用于通知 ID 和本地课表标识，不能使用 [Object.hash] 或 [String.hashCode]，
/// 因为它们只保证当前运行时内可比较，不是磁盘数据的稳定协议。
int deterministicStringHash(String value) {
  final digest = sha256.convert(utf8.encode(value));
  var result = 0;
  for (final byte in digest.bytes.take(4)) {
    result = (result << 8) | byte;
  }
  result &= 0x7fffffff;
  return result == 0 ? 1 : result;
}

/// 根据课程的稳定字段生成本地持久化 ID。
///
/// 周次使用排序后的集合，保证“1-8 周”和对应的整数列表得到同一标识；
/// 若教务源提供课程/教学班编号，则优先纳入 [courseCode]，减少展示字段变化带来的漂移。
int deterministicCourseId({
  required String courseCode,
  required String name,
  required String? teacher,
  required String? location,
  required int weekday,
  required int startSection,
  required int endSection,
  required Iterable<int> weeks,
}) {
  final normalizedWeeks = weeks.where((week) => week > 0).toSet().toList()..sort();
  final canonical = [
    'v1',
    courseCode.trim(),
    name.trim(),
    teacher?.trim() ?? '',
    location?.trim() ?? '',
    weekday,
    startSection,
    endSection,
    normalizedWeeks.join(','),
  ].join('\u001f');
  return deterministicStringHash(canonical);
}

int deterministicCourseColorIndex(String name, int poolLength) {
  if (poolLength <= 0) throw ArgumentError.value(poolLength, 'poolLength');
  return deterministicStringHash('course-color-v1\u001f${name.trim()}') % poolLength;
}
