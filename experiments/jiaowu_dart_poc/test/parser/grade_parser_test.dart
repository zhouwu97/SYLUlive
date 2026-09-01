import 'dart:io';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:test/test.dart';

void main() {
  test('GradeParser 保留成绩 items 的完整原始字段', () {
    final body = File('test/fixtures/grades/normal.json').readAsStringSync();

    final payload = GradeParser.parse(body);

    expect(payload.grades, hasLength(1));
    expect(payload.validEmpty, isFalse);
    expect(payload.grades.single.raw['kcmc'], '高等数学');
    expect(payload.grades.single.raw['xh'], 'TEST_STUDENT');
    expect(payload.grades.single.raw['extra'], {
      'source': 'fixture',
      'active': true,
    });

    final canonical = payload.grades.single.toCanonicalJson();
    expect(canonical, isNot(contains('TEST_STUDENT')));
    expect(canonical.keys, isNot(contains('key')));
    expect(canonical.keys, isNot(contains('bh')));
  });

  test('结构正确的 items=[] 是合法空成绩结果', () {
    final body = File('test/fixtures/grades/empty.json').readAsStringSync();

    final payload = GradeParser.parse(body);

    expect(payload.grades, isEmpty);
    expect(payload.validEmpty, isTrue);
  });

  test('缺失、空值或错误类型的 items 都视为协议变化', () {
    final invalidBodies = [
      File('test/fixtures/grades/missing_items.json').readAsStringSync(),
      File('test/fixtures/grades/items_null.json').readAsStringSync(),
      File('test/fixtures/grades/items_wrong_type.json').readAsStringSync(),
      'null',
    ];

    for (final body in invalidBodies) {
      expect(
        () => GradeParser.parse(body),
        throwsA(isA<ProtocolChangedException>()),
      );
    }
  });

  test('malformed JSON 和 HTML 不会被当成空成绩', () {
    final invalidBodies = [
      File('test/fixtures/grades/malformed.json').readAsStringSync(),
      File('test/fixtures/grades/maintenance.html').readAsStringSync(),
    ];

    for (final body in invalidBodies) {
      expect(
        () => GradeParser.parse(body),
        throwsA(isA<ParseException>()),
      );
    }
  });
}
