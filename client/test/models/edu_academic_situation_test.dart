import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/edu_academic_situation.dart';

void main() {
  test('学业情况解析来源元数据和抓取时间', () {
    final result = EduAcademicSituation.fromJson({
      'success': true,
      'source_kind': 'official_academic_situation',
      'source_url': '/xsxy/xsxyqk_cxXsxyqkIndex.html',
      'parser_version': 'academic-situation-v2',
      'captured_at': '2026-07-21T08:00:00Z',
      'official_updated_at': null,
      'structure_signature': 'abc123',
      'all_gpa': 3.21,
      'degree_gpa': 3.16,
      'total_courses': 48,
      'passed_courses': 43,
      'failed_courses': 1,
      'not_started_courses': 2,
      'in_progress_courses': 2,
      'courses_status': 'dynamic_source_unresolved',
      'courses': const <Object>[],
    });

    expect(result.success, isTrue);
    expect(result.sourceKind, 'official_academic_situation');
    expect(result.parserVersion, 'academic-situation-v2');
    expect(result.capturedAt, DateTime.utc(2026, 7, 21, 8));
    expect(result.officialUpdatedAt, isNull);
    expect(result.coursesStatus, 'dynamic_source_unresolved');
    expect(result.courses, isEmpty);
  });

  test('结构变化响应保留错误信息且兼容旧时间字段', () {
    final result = EduAcademicSituation.fromJson({
      'success': false,
      'error_code': 'ACADEMIC_SITUATION_STRUCTURE_CHANGED',
      'message': '学业情况页面结构发生变化',
      'courses_status': 'parse_failed',
      'updated_at': '2026-07-21T09:00:00Z',
    });

    expect(result.success, isFalse);
    expect(result.errorCode, 'ACADEMIC_SITUATION_STRUCTURE_CHANGED');
    expect(result.message, '学业情况页面结构发生变化');
    expect(result.coursesStatus, 'parse_failed');
    expect(result.capturedAt, DateTime.utc(2026, 7, 21, 9));
  });
}
