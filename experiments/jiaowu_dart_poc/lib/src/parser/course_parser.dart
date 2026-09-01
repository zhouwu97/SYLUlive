import 'dart:convert';

import '../error/jiaowu_exception.dart';
import '../model/raw_course.dart';

/// 一次 JSON 响应的结构化结果，用于区分合法空列表和非法响应。
final class ParsedCoursePayload {
  const ParsedCoursePayload({required this.courses});

  final List<RawCourse> courses;
  bool get validEmpty => courses.isEmpty;
}

/// 只负责把服务器 JSON 映射为 RawCourse，不处理网络 fallback 和业务状态。
abstract final class CourseParser {
  static ParsedCoursePayload parse(String body) {
    if (body.trim().isEmpty || body.trim() == 'null') {
      throw const ParseException(
        message: '课表接口返回空响应',
        code: 'COURSE_EMPTY_RESPONSE',
      );
    }

    final decoded = _decodeJson(body);
    if (decoded is! Map<String, dynamic>) {
      throw const ProtocolChangedException(
        message: '课表接口响应不是对象结构',
      );
    }
    final rawList = decoded['kbList'];
    if (rawList is! List<dynamic>) {
      throw const ProtocolChangedException(
        message: '课表接口缺少 kbList 字段',
      );
    }

    final courses = <RawCourse>[];
    for (var index = 0; index < rawList.length; index++) {
      final item = rawList[index];
      if (item is! Map<String, dynamic>) {
        throw ProtocolChangedException(
          message: '课表 kbList 第 ${index + 1} 条记录结构异常',
        );
      }
      final weekDay = _parseWeekDay(item['xqj'], index: index);
      courses.add(
        RawCourse(
          name: _stringValue(item['kcmc']),
          teacher: _stringValue(item['xm']),
          location: _stringValue(item['cdmc']),
          section: _stringValue(item['jc']),
          weekDay: weekDay,
          weekExpression: _stringValue(item['zcd']),
        ),
      );
    }
    return ParsedCoursePayload(courses: List.unmodifiable(courses));
  }

  static dynamic _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw ParseException(
        message: '课表接口返回无法解析的 JSON',
        code: 'COURSE_JSON_INVALID',
        cause: error,
      );
    }
  }

  static String _stringValue(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  static String _parseWeekDay(Object? value, {required int index}) {
    final weekDay = _stringValue(value);
    final parsed = int.tryParse(weekDay);
    if (parsed == null || parsed < 1 || parsed > 7) {
      throw ProtocolChangedException(
        message: '课表 kbList 第 ${index + 1} 条记录的 xqj 无效',
      );
    }
    return weekDay;
  }
}
