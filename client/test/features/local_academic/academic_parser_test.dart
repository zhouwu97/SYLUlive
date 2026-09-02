import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/local_academic/academic_parser.dart';
import 'package:shenliyuan/features/local_academic/schema_mismatch.dart';

void main() {
  group('AcademicParser 正常与空数据', () {
    test('解析已审核的成绩 HTML 表格', () {
      final rows = AcademicParser.parseGrades(_fixture('normal_grades.html'));

      expect(rows, hasLength(1));
      expect(rows.single, containsPair('name', '数据结构'));
      expect(rows.single, containsPair('grade', '91'));
      expect(rows.single, containsPair('credits', '3'));
    });

    test('明确成功的空成绩列表保持为空', () {
      expect(
        AcademicParser.parseGrades(_fixture('empty_grades.json')),
        isEmpty,
      );
    });

    test('完全相同的重复记录去重', () {
      final rows = AcademicParser.parseGrades(
        _fixture('duplicate_grades.json'),
      );

      expect(rows, hasLength(1));
      expect(rows.single['grade'], '91');
    });
  });

  group('AcademicParser fail-closed', () {
    test('登录页和 Session 过期响应不会伪装为空数据', () {
      for (final name in <String>['login_page.html', 'session_expired.json']) {
        expect(
          () => AcademicParser.parseGrades(_fixture(name)),
          throwsA(
            isA<SchemaMismatch>().having(
              (error) => error.dataset,
              'dataset',
              'grades',
            ),
          ),
        );
      }
    });

    test('未知 HTML 结构和必要字段缺失均拒绝', () {
      for (final name in <String>[
        'changed_structure.html',
        'missing_required_field.json',
      ]) {
        expect(
          () => AcademicParser.parseGrades(_fixture(name)),
          throwsA(isA<SchemaMismatch>()),
        );
      }
    });

    test('相同业务键对应冲突内容时拒绝', () {
      expect(
        () => AcademicParser.parseGrades(
          _fixture('conflicting_duplicate_grades.json'),
        ),
        throwsA(isA<SchemaMismatch>()),
      );
    });

    test('异常 JSON 和未知顶层类型均拒绝', () {
      expect(
        () => AcademicParser.parseGrades(_fixture('malformed.json')),
        throwsA(isA<SchemaMismatch>()),
      );
      expect(
        () => AcademicParser.parseGrades(42),
        throwsA(isA<SchemaMismatch>()),
      );
    });

    test('响应回显学期与请求不一致时拒绝', () {
      expect(
        () => AcademicParser.parseGrades(
          const <String, dynamic>{
            'success': true,
            'grades': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': '数据结构',
                'grade': '91',
                'year': '2025',
                'semester': 2,
              },
            ],
          },
          year: '2026',
          semester: 1,
        ),
        throwsA(isA<SchemaMismatch>()),
      );
    });
  });
}

String _fixture(String name) {
  return File('test/fixtures/academic/$name').readAsStringSync();
}
