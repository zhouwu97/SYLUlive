import 'dart:convert';
import 'dart:io';

import 'package:jiaowu_dart_poc/src/core/jiaowu_client.dart';

/// Dart 端成绩详情查询工具。
///
/// 用于 Python ↔ Dart differential 验证。
///
/// 使用方式：
///     dart run tools/differential/dart_query.dart
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
    stderr.writeln('登录成功');

    // 获取成绩列表（使用当前学年学期）
    stderr.writeln('正在获取成绩列表...');
    final gradeResult = await client.getGrades(
      year: '2025',
      semester: 12,
    );
    stderr.writeln('获取到 ${gradeResult.grades.length} 条成绩记录');

    if (gradeResult.grades.isEmpty) {
      stderr.writeln('警告: 没有成绩记录');
      exit(0);
    }

    // 选择有完整 ID 的成绩
    final validGrades = gradeResult.grades
        .where((g) =>
            (g.raw['jxb_id'] as String? ?? '').isNotEmpty &&
            (g.raw['kcmc'] as String? ?? '').isNotEmpty)
        .toList();

    if (validGrades.isEmpty) {
      stderr.writeln('警告: 没有包含完整 ID 的成绩记录');
      exit(0);
    }

    stderr.writeln('找到 ${validGrades.length} 条有效成绩记录');

    // 查询前两门课程的成绩详情
    final results = <Map<String, dynamic>>[];

    for (var i = 0; i < validGrades.length && i < 2; i++) {
      final grade = validGrades[i];
      final courseName = grade.raw['kcmc'] as String? ?? '';
      final year = grade.raw['xnm'] as String? ?? '';
      final semester = int.tryParse(grade.raw['xqm']?.toString() ?? '') ?? 0;
      final classId = grade.raw['jxb_id'] as String? ?? '';
      final courseId = grade.raw['kch_id'] as String? ?? '';
      final studentGradeId = grade.raw['xh_id'] as String? ?? '';

      stderr.writeln(
          '正在查询课程 ${i + 1}/${validGrades.length.clamp(0, 2)}: $courseName');

      try {
        final detail = await client.getGradeDetail(
          year: year,
          semester: semester,
          classId: classId,
          courseName: courseName,
          courseId: courseId.isEmpty ? null : courseId,
          studentGradeId: studentGradeId.isEmpty ? null : studentGradeId,
        );

        results.add({
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
          'query_params': {
            'year': year,
            'semester': semester,
            'class_id': classId,
            'course_name': courseName,
            'course_id': courseId.isEmpty ? null : courseId,
            'student_grade_id': studentGradeId.isEmpty ? null : studentGradeId,
          },
        });

        stderr.writeln(
            '  成功: ${detail.success}, 分项数: ${detail.components.length}');
      } catch (e) {
        stderr.writeln('  查询失败: $e');
        results.add({
          'success': false,
          'course_name': courseName,
          'error': e.toString(),
          'query_params': {
            'year': year,
            'semester': semester,
            'class_id': classId,
            'course_name': courseName,
          },
        });
      }
    }

    // 输出 JSON 到 stdout
    stdout.write(jsonEncode(results));
    stderr.writeln('\n查询完成');
  } catch (e, stackTrace) {
    stderr.writeln('错误: $e');
    stderr.writeln(stackTrace);
    exit(1);
  }
}
