import 'dart:io';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

void main() {
  test('CourseParser 保留 kbList 原始记录，不按课程三字段去重', () {
    final body = File(
      'test/fixtures/courses/desktop_normal.json',
    ).readAsStringSync();

    final payload = CourseParser.parse(body);

    expect(payload.courses, hasLength(3));
    expect(payload.courses[0], const TypeMatcher<RawCourse>());
    expect(payload.courses[0].name, '高等数学');
    expect(payload.courses[0].teacher, '张老师');
    expect(payload.courses[0].location, 'A101');
    expect(payload.courses[0].section, '1-2节');
    expect(payload.courses[0].weekDay, '1');
    expect(payload.courses[0].weekExpression, '1-8周');
    expect(payload.courses[1].location, 'A202');
    expect(payload.validEmpty, isFalse);
  });

  test('结构正确的 kbList=[] 才是合法空课表', () {
    final body = File(
      'test/fixtures/courses/desktop_empty.json',
    ).readAsStringSync();

    final payload = CourseParser.parse(body);

    expect(payload.courses, isEmpty);
    expect(payload.validEmpty, isTrue);
  });

  test('异常响应不被解析成空课表', () {
    final invalidBodies = [
      File('test/fixtures/courses/malformed.json').readAsStringSync(),
      File('test/fixtures/courses/missing_kblist.json').readAsStringSync(),
      '[]',
      'null',
      File('test/fixtures/courses/maintenance.html').readAsStringSync(),
    ];

    for (final body in invalidBodies) {
      expect(
        () => CourseParser.parse(body),
        throwsA(isA<ParseException>()),
      );
    }
  });

  test('xqj 缺失或超出 1 到 7 时拒绝伪造星期', () {
    const invalidWeekdays = [
      '{"kbList":[{"kcmc":"课程","xqj":null}]}',
      '{"kbList":[{"kcmc":"课程","xqj":0}]}',
      '{"kbList":[{"kcmc":"课程","xqj":8}]}',
      '{"kbList":[{"kcmc":"课程","xqj":"周一"}]}',
    ];

    for (final body in invalidWeekdays) {
      expect(
        () => CourseParser.parse(body),
        throwsA(isA<ProtocolChangedException>()),
      );
    }
  });
}
