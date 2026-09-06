import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'package:shenliyuan/features/academic/data/mapper/raw_grade_mapper.dart';
import 'package:shenliyuan/models/edu_grade.dart';

void main() {
  test('学校 RawGrade 会完整映射为主应用 EduGrade 字段', () {
    final normalized = RawGradeMapper.toAppJson(
      RawGrade(
        raw: <String, Object?>{
          'kcmc': '高等数学',
          'jxb_id': 'JXB001',
          'kch_id': 'KC001',
          'kch': 'MATH101',
          'xh_id': 'XH001',
          'jsxm': '张老师',
          'sfxwkc': '是',
          'xf': '4',
          'jd': '3.8',
          'xfjd': '15.2',
          'bfzcj': '88',
          'cj': '88',
          'ksxz': '正常考试',
          'kklxdm': '主修课程',
          'khfsmc': '考试',
        },
      ),
    );
    final grade = EduGrade.fromJson(normalized);

    expect(grade.name, '高等数学');
    expect(grade.classId, 'JXB001');
    expect(grade.studentGradeId, 'XH001');
    expect(grade.courseId, 'KC001');
    expect(grade.courseCode, 'MATH101');
    expect(grade.displayGrade, '88');
    expect(grade.credits, 4);
    expect(grade.gpa, 3.8);
    expect(grade.gradePoints, 15.2);
    expect(grade.fraction, 88);
    expect(grade.teacher, '张老师');
    expect(grade.examType, '正常考试');
    expect(grade.courseCategory, '主修课程');
    expect(grade.assessmentMethod, '考试');
    expect(grade.isDegree, isTrue);
  });
}
