import 'dart:convert';

import '../error/jiaowu_exception.dart';
import '../model/raw_grade.dart';

/// 一次成绩 JSON 响应的结构化结果。
final class ParsedGradePayload {
  ParsedGradePayload({required Iterable<RawGrade> grades})
      : grades = List.unmodifiable(grades);

  final List<RawGrade> grades;
  bool get validEmpty => grades.isEmpty;
}

/// 严格解析成绩列表响应，不把缺失 items 静默降级为空列表。
abstract final class GradeParser {
  static ParsedGradePayload parse(String body) {
    if (body.trim().isEmpty) {
      throw const ParseException(
        message: '成绩接口返回空响应',
        code: 'GRADE_EMPTY_RESPONSE',
      );
    }

    final decoded = _decodeJson(body);
    if (decoded is! Map<String, dynamic>) {
      throw const ProtocolChangedException(
        message: '成绩接口响应不是对象结构',
      );
    }
    if (!decoded.containsKey('items') || decoded['items'] is! List<dynamic>) {
      throw const ProtocolChangedException(
        message: '成绩接口缺少有效 items 字段',
      );
    }

    final rawItems = decoded['items'] as List<dynamic>;
    final grades = <RawGrade>[];
    for (var index = 0; index < rawItems.length; index++) {
      final item = rawItems[index];
      if (item is! Map<String, dynamic>) {
        throw ProtocolChangedException(
          message: '成绩 items 第 ${index + 1} 条记录结构异常',
        );
      }
      grades.add(RawGrade(raw: Map<String, Object?>.from(item)));
    }
    return ParsedGradePayload(grades: grades);
  }

  static dynamic _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw ParseException(
        message: '成绩接口返回无法解析的 JSON',
        code: 'GRADE_JSON_INVALID',
        cause: error,
      );
    }
  }
}
