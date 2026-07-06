import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/models/grade_reminder_snapshot.dart';

void main() {
  group('GradeReminderSnapshot', () {
    test('首次空基线会初始化但不产生提醒', () {
      final next = GradeReminderSnapshot.fromGrades(const []);
      final diff = next.diffFrom(null);

      expect(next.initialized, true);
      expect(next.grades, isEmpty);
      expect(diff.baselineOnly, true);
      expect(diff.hasChanges, false);
    });

    test('空基线到有成绩会提醒', () {
      final old = GradeReminderSnapshot.empty();
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: '计算机网络', grade: '88', classId: 'jxb-1'),
      ]);

      final diff = next.diffFrom(old);

      expect(diff.hasChanges, true);
      expect(diff.changes.single.summary, '计算机网络: -- -> 88');
    });

    test('-- 到 88 会提醒', () {
      final old = GradeReminderSnapshot.fromGrades([
        _grade(name: '数据结构', grade: '--', classId: 'jxb-1'),
      ]);
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: '数据结构', grade: '88', classId: 'jxb-1'),
      ]);

      expect(next.diffFrom(old).hasChanges, true);
    });

    test('未录入到良好会提醒', () {
      final old = GradeReminderSnapshot.fromGrades([
        _grade(name: '大学物理', grade: '未录入', classId: 'jxb-1'),
      ]);
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: '大学物理', grade: '良好', classId: 'jxb-1'),
      ]);

      final diff = next.diffFrom(old);

      expect(diff.hasChanges, true);
      expect(diff.changes.single.summary, '大学物理: 未录入 -> 良好');
    });

    test('85 到 90 会提醒', () {
      final old = GradeReminderSnapshot.fromGrades([
        _grade(name: '高等数学', grade: '85', classId: 'jxb-1'),
      ]);
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: '高等数学', grade: '90', classId: 'jxb-1'),
      ]);

      expect(next.diffFrom(old).hasChanges, true);
    });

    test('排序变化不提醒', () {
      final old = GradeReminderSnapshot.fromGrades([
        _grade(name: 'A', grade: '80', classId: 'a'),
        _grade(name: 'B', grade: '90', classId: 'b'),
      ]);
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: 'B', grade: '90', classId: 'b'),
        _grade(name: 'A', grade: '80', classId: 'a'),
      ]);

      expect(next.diffFrom(old).hasChanges, false);
    });

    test('教师变化不提醒', () {
      final old = GradeReminderSnapshot.fromGrades([
        _grade(name: '线性代数', grade: '90', classId: 'jxb-1', teacher: '张老师'),
      ]);
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: '线性代数', grade: '90', classId: 'jxb-1', teacher: '李老师'),
      ]);

      expect(next.diffFrom(old).hasChanges, false);
    });

    test('相同变化 hash 相同', () {
      final old = GradeReminderSnapshot.empty();
      final next = GradeReminderSnapshot.fromGrades([
        _grade(name: '操作系统', grade: '95', classId: 'jxb-1'),
      ]);

      final a = next.diffFrom(old).changeHash;
      final b = next.diffFrom(old).changeHash;

      expect(a, isNotEmpty);
      expect(a, b);
    });

    test('稳定 key 按优先级选择 studentGradeId', () {
      final snapshot = GradeReminderSnapshot.fromGrades([
        _grade(
          name: '编译原理',
          grade: '91',
          studentGradeId: 'sg-1',
          classId: 'class-1',
          courseId: 'course-1',
        ),
      ]);

      expect(snapshot.grades.single.key, 'student:sg-1');
    });
  });
}

EduGrade _grade({
  required String name,
  required String grade,
  String classId = '',
  String studentGradeId = '',
  String courseId = '',
  String courseCode = '',
  String? teacher,
}) {
  return EduGrade(
    name: name,
    classId: classId,
    studentGradeId: studentGradeId,
    courseId: courseId,
    courseCode: courseCode,
    displayGrade: grade,
    credits: 3,
    gpa: null,
    teacher: teacher,
    fraction: double.tryParse(grade),
    examType: '正常考试',
    isDegree: true,
  );
}
