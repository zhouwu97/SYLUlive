import 'dart:convert';
import 'dart:io';

import 'package:jiaowu_dart_poc/src/core/jiaowu_client.dart';

/// Dart 端三大功能综合查询工具。
///
/// 用于 Python ↔ Dart differential 验证：
/// - Grade Detail (成绩详情)
/// - Academic Situation (学业情况/GPA)
/// - Credit Requirement (学分要求)
///
/// 使用方式：
///     dart run tools/differential/dart_query_all.dart
///
/// 环境变量：
///     JIAOWU_USERNAME: 学号
///     JIAOWU_PASSWORD: 密码
Future<void> main(List<String> args) async {
  final username = Platform.environment['JIAOWU_USERNAME'];
  final password = Platform.environment['JIAOWU_PASSWORD'];

  if (username == null || password == null) {
    stderr.writeln('错误: 缺少环境变量 JIAOWU_USERNAME 或 JIAOWU_PASSWORD');
    exit(1);
  }

  try {
    final client = JiaowuClient();

    // 登录
    stderr.writeln('正在登录...');
    await client.login(studentId: username, password: password);
    stderr.writeln('登录成功\n');

    final results = <String, dynamic>{};

    // ===== 1. Academic Situation =====
    stderr.writeln('【1/3】正在查询学业情况 (Academic Situation)...');
    try {
      final situation = await client.getAcademicSituation();
      results['academic_situation'] = {
        'success': situation.success,
        'all_gpa': situation.allGpa,
        'degree_gpa': situation.degreeGpa,
        'total_courses': situation.totalCourses,
        'passed_courses': situation.passedCourses,
        'failed_courses': situation.failedCourses,
        'not_started_courses': situation.notStartedCourses,
        'in_progress_courses': situation.inProgressCourses,
        'degree_total_courses': situation.degreeTotalCourses,
        'degree_passed_courses': situation.degreePassedCourses,
        'degree_failed_courses': situation.degreeFailedCourses,
        'degree_not_started_courses': situation.degreeNotStartedCourses,
        'degree_in_progress_courses': situation.degreeInProgressCourses,
        'courses_status': situation.coursesStatus,
        'courses': situation.courses
            .map((c) => {
                  'course_name': c.courseName,
                  'course_id': c.courseId,
                  'credits': c.credits,
                  'status': c.status,
                  'effective_grade': c.effectiveGrade,
                  'effective_passed': c.effectivePassed,
                  'is_degree': c.isDegree,
                  'has_retake': c.hasRetake,
                  'max_grade': c.maxGrade,
                  'gpa': c.gpa,
                  'course_category': c.courseCategory,
                  'course_nature': c.courseNature,
                })
            .toList(),
        'message': situation.message,
      };
      stderr.writeln('  ✅ 成功: GPA=${situation.allGpa}, '
          '课程数=${situation.courses.length}\n');
    } catch (e) {
      stderr.writeln('  ❌ 失败: $e\n');
      results['academic_situation'] = {
        'success': false,
        'error': e.toString(),
      };
    }

    // ===== 2. Credit Requirement =====
    stderr.writeln('【2/3】正在查询学分要求 (Credit Requirement)...');
    try {
      final requirement = await client.getCreditRequirement();
      results['credit_requirement'] = {
        'success': requirement.success,
        'status': requirement.status,
        'modules': requirement.modules
            .map((m) => {
                  'name': m.name,
                  'required_credits': m.requiredCredits,
                  'earned_credits': m.earnedCredits,
                  'status': m.status,
                  'required_course_count': m.requiredCourseCount,
                  'courses': m.courses
                      .map((c) => {
                            'course_id': c.courseId,
                            'course_name': c.courseName,
                            'credits': c.credits,
                            'grade': c.grade,
                            'status': c.status,
                            'suggested_year': c.suggestedYear,
                            'suggested_semester': c.suggestedSemester,
                            'actual_year': c.actualYear,
                            'actual_semester': c.actualSemester,
                          })
                      .toList(),
                })
            .toList(),
        'improvement_courses': requirement.improvementCourses
            .map((c) => {
                  'course_id': c.courseId,
                  'course_name': c.courseName,
                  'credits': c.credits,
                  'grade': c.grade,
                  'status': c.status,
                })
            .toList(),
        'message': requirement.message,
      };
      stderr.writeln('  ✅ 成功: 模块数=${requirement.modules.length}, '
          '待提升课程=${requirement.improvementCourses.length}\n');
    } catch (e) {
      stderr.writeln('  ❌ 失败: $e\n');
      results['credit_requirement'] = {
        'success': false,
        'error': e.toString(),
      };
    }

    // ===== 3. Grade Detail =====
    stderr.writeln('【3/3】正在查询成绩详情 (Grade Detail)...');
    // 获取成绩列表
    final gradeResult = await client.getGrades(year: '2025', semester: 12);
    final validGrades = gradeResult.grades
        .where((g) =>
            (g.raw['jxb_id'] as String? ?? '').isNotEmpty &&
            (g.raw['kcmc'] as String? ?? '').isNotEmpty)
        .toList();

    if (validGrades.isEmpty) {
      stderr.writeln('  ⚠️  警告: 没有可查询的成绩记录\n');
      results['grade_details'] = [];
    } else {
      final gradeDetails = <Map<String, dynamic>>[];

      for (var i = 0; i < validGrades.length && i < 2; i++) {
        final grade = validGrades[i];
        final courseName = grade.raw['kcmc'] as String? ?? '';
        final year = grade.raw['xnm'] as String? ?? '';
        final semester =
            int.tryParse(grade.raw['xqm']?.toString() ?? '') ?? 0;
        final classId = grade.raw['jxb_id'] as String? ?? '';
        final courseId = grade.raw['kch_id'] as String? ?? '';
        final studentGradeId = grade.raw['xh_id'] as String? ?? '';

        stderr.writeln('  正在查询课程 ${i + 1}/2: $courseName');

        try {
          final detail = await client.getGradeDetail(
            year: year,
            semester: semester,
            classId: classId,
            courseName: courseName,
            courseId: courseId.isEmpty ? null : courseId,
            studentGradeId: studentGradeId.isEmpty ? null : studentGradeId,
          );

          gradeDetails.add({
            'success': detail.success,
            'course_name': detail.courseName,
            'total_grade': detail.totalGrade,
            'components': detail.components
                .map((c) => {
                      'name': c.name,
                      'weight': c.weight,
                      'score': c.score,
                    })
                .toList(),
            'message': detail.message,
          });

          stderr.writeln('    ✅ 成功: 总评=${detail.totalGrade}, '
              '分项数=${detail.components.length}');
        } catch (e) {
          stderr.writeln('    ❌ 失败: $e');
          gradeDetails.add({
            'success': false,
            'course_name': courseName,
            'error': e.toString(),
          });
        }
      }

      results['grade_details'] = gradeDetails;
      stderr.writeln();
    }

    // 输出 JSON 到 stdout
    stdout.write(jsonEncode(results));
    stderr.writeln('✅ 所有查询完成');
  } catch (e, stackTrace) {
    stderr.writeln('❌ 错误: $e');
    stderr.writeln(stackTrace);
    exit(1);
  }
}
