import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';

void main() {
  test('服务端数据源恢复成绩详情、学业情况和学分要求能力', () async {
    final requestedPaths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add(options.path);
            final payload = switch (options.path) {
              '/edu/status' => const <String, dynamic>{
                  'success': true,
                  'edu_authorized': true,
                  'edu_student_id': '2026000001',
                  'edu_session_state': 'active',
                },
              '/edu/grades/detail' => const <String, dynamic>{
                  'success': true,
                  'course_name': '数据结构',
                  'total_grade': '88',
                  'components': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': '平时',
                      'weight': '40%',
                      'score': '90',
                    },
                  ],
                },
              '/edu/academic-situation' => const <String, dynamic>{
                  'success': true,
                  'all_gpa': 3.7,
                  'degree_gpa': 3.6,
                  'total_courses': 12,
                  'passed_courses': 11,
                  'failed_courses': 1,
                  'not_started_courses': 0,
                  'in_progress_courses': 0,
                  'degree_total_courses': 10,
                  'degree_passed_courses': 9,
                  'degree_failed_courses': 1,
                  'degree_not_started_courses': 0,
                  'degree_in_progress_courses': 0,
                  'courses_status': 'complete',
                  'courses': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'course_code': 'CS101',
                      'course_name': '数据结构',
                      'credits': 3,
                      'study_status': '已通过',
                      'effective_grade': '88',
                      'effective_passed': true,
                      'is_degree': true,
                      'has_retake': false,
                    },
                  ],
                },
              '/edu/credit-requirements' => const <String, dynamic>{
                  'success': true,
                  'status': 'available',
                  'modules': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': '专业必修',
                      'required_credits': 30,
                      'earned_credits': 12,
                      'status': 'in_progress',
                      'courses': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'course_code': 'CS101',
                          'course_name': '数据结构',
                          'credits': 3,
                          'grade': '88',
                          'raw_status': '已通过',
                        },
                      ],
                    },
                  ],
                  'improvement_courses': <Map<String, dynamic>>[],
                },
              _ => throw StateError('未预期的请求: ${options.path}'),
            };
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: payload,
              ),
            );
          },
        ),
      );
    final source = LegacyServerDataSource(dio, networkEnabled: true);

    expect(const AcademicCapabilities.legacy().supportsGradeDetail, isTrue);
    expect(
      const AcademicCapabilities.legacy().supportsAcademicSituation,
      isTrue,
    );
    expect(
      const AcademicCapabilities.legacy().supportsCreditRequirements,
      isTrue,
    );

    await source.restoreSession();
    final detail = await source.getGradeDetail(
      year: '2026',
      semester: 3,
      classId: 'class-id',
      courseName: '数据结构',
      courseId: 'CS101',
      studentGradeId: 'grade-id',
    );
    final situation = await source.getAcademicSituation();
    final requirements = await source.getCreditRequirements();

    expect(detail.totalGrade, '88');
    expect(detail.components.single.name, '平时');
    expect(situation.allGpa, 3.7);
    expect(situation.courses.single.courseId, 'CS101');
    expect(requirements.modules.single.name, '专业必修');
    expect(requirements.modules.single.courses.single.courseName, '数据结构');
    expect(
      requestedPaths,
      containsAll(<String>[
        '/edu/status',
        '/edu/grades/detail',
        '/edu/academic-situation',
        '/edu/credit-requirements',
      ]),
    );
  });
}
