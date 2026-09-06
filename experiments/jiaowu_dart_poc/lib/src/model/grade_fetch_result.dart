import 'dart:convert';

import 'raw_grade.dart';

/// 一次成绩查询的结果及其稳定 JSON 视图。
final class GradeFetchResult {
  GradeFetchResult({required Iterable<RawGrade> grades, required this.pages})
      : grades = List.unmodifiable(grades);

  final List<RawGrade> grades;
  final int pages;

  bool get validEmpty => grades.isEmpty;
  bool get isEmpty => grades.isEmpty;

  /// 只输出脱离账号身份字段后的成绩记录，并按完整 JSON 稳定排序。
  List<Map<String, Object?>> get canonicalJson {
    final records = grades.map((grade) => grade.toCanonicalJson()).toList();
    records.sort(
      (left, right) => jsonEncode(left).compareTo(jsonEncode(right)),
    );
    return records;
  }
}
