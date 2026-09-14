import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/utils/edu_semester_utils.dart';

void main() {
  group('EduGrade.fromJson', () {
    test('parses numeric fields correctly', () {
      final json = {
        'name': '数据结构',
        'class_id': 'JXB001',
        'student_grade_id': 'OPAQUE_XH_ID',
        'course_id': '210300001',
        'course_code': '210300001',
        'grade': '85.5',
        'credits': 3.0,
        'gpa': 3.5,
        'teacher': '王老师',
        'grade_points': 10.5,
        'fraction': '85.5',
        'exam_type': '正常考试',
        'course_category': '主修课程',
        'assessment_method': '考试',
        'is_degree': true,
      };
      final g = EduGrade.fromJson(json);
      expect(g.name, '数据结构');
      expect(g.classId, 'JXB001');
      expect(g.studentGradeId, 'OPAQUE_XH_ID');
      expect(g.courseId, '210300001');
      expect(g.courseCode, '210300001');
      expect(g.displayGrade, '85.5');
      expect(g.credits, 3.0);
      expect(g.gpa, 3.5);
      expect(g.teacher, '王老师');
      expect(g.gradePoints, 10.5);
      expect(g.fraction, 85.5);
      expect(g.examType, '正常考试');
      expect(g.courseCategory, '主修课程');
      expect(g.assessmentMethod, '考试');
      expect(g.isDegree, true);
    });

    test('handles int credits and int gpa', () {
      final json = {
        'name': '体育',
        'grade': '84',
        'credits': 1,
        'gpa': 3,
        'is_degree': false,
      };
      final g = EduGrade.fromJson(json);
      expect(g.credits, 1.0);
      expect(g.gpa, 3.0);
      expect(g.isDegree, false);
    });

    test('handles string credits and string gpa', () {
      final json = {
        'name': '数学分析',
        'grade': '90',
        'credits': '4',
        'gpa': '4.0',
        'is_degree': true,
      };
      final g = EduGrade.fromJson(json);
      expect(g.credits, 4.0);
      expect(g.gpa, 4.0);
    });

    test('handles null gpa', () {
      final json = {
        'name': '形势与政策',
        'grade': '合格',
        'credits': 0.5,
        'gpa': null,
        'is_degree': false,
      };
      final g = EduGrade.fromJson(json);
      expect(g.gpa, isNull);
    });

    test('handles null and missing fields gracefully', () {
      final json = <String, dynamic>{};
      final g = EduGrade.fromJson(json);
      expect(g.name, '');
      expect(g.classId, '');
      expect(g.studentGradeId, '');
      expect(g.courseId, '');
      expect(g.displayGrade, '--');
      expect(g.credits, 0);
      expect(g.gpa, isNull);
      expect(g.teacher, isNull);
      expect(g.gradePoints, isNull);
      expect(g.fraction, isNull);
      expect(g.isDegree, false);
    });

    test('handles is_degree as int 1', () {
      final json = {
        'name': '测试',
        'grade': '60',
        'credits': 2,
        'gpa': 1.0,
        'is_degree': 1,
      };
      final g = EduGrade.fromJson(json);
      expect(g.isDegree, true);
    });

    test('handles is_degree as int 0', () {
      final json = {
        'name': '测试',
        'grade': '60',
        'credits': 2,
        'gpa': 1.0,
        'is_degree': 0,
      };
      final g = EduGrade.fromJson(json);
      expect(g.isDegree, false);
    });

    test('handles is_degree as string 是', () {
      final json = {
        'name': '测试',
        'grade': '60',
        'credits': 2,
        'gpa': 1.0,
        'is_degree': '是',
      };
      final g = EduGrade.fromJson(json);
      expect(g.isDegree, true);
    });
  });

  group('EduGradeDetail.fromJson', () {
    test('parses grade components', () {
      final detail = EduGradeDetail.fromJson({
        'success': true,
        'course_name': '电磁场与电磁波',
        'total_grade': '60.1',
        'components': [
          {'name': '平时', 'weight': '15%', 'score': '98'},
          {'name': '期末', 'weight': '60%', 'score': '40'},
          {'name': '总评', 'weight': '', 'score': '60.1'},
        ],
      });

      expect(detail.success, true);
      expect(detail.courseName, '电磁场与电磁波');
      expect(detail.totalGrade, '60.1');
      expect(detail.components.length, 3);
      expect(detail.components.first.weight, '15%');
      expect(detail.components.last.weight, isNull);
      expect(detail.components.last.score, '60.1');
    });
  });

  group('EduGrade.isPassed', () {
    // Numeric: pass
    test('numeric >= 60 is passed', () {
      expect(_grade('90').isPassed, true);
      expect(_grade('85.5').isPassed, true);
      expect(_grade('60').isPassed, true);
      expect(_grade('100').isPassed, true);
    });

    // Numeric: fail
    test('numeric < 60 is failed', () {
      expect(_grade('59.9').isPassed, false);
      expect(_grade('0').isPassed, false);
      expect(_grade('30').isPassed, false);
    });

    // Text: pass
    test('text 优秀/良好/中等/合格/及格 is passed', () {
      expect(_grade('优秀').isPassed, true);
      expect(_grade('良好').isPassed, true);
      expect(_grade('中等').isPassed, true);
      expect(_grade('合格').isPassed, true);
      expect(_grade('及格').isPassed, true);
    });

    // Text: fail
    test('text 不及格/不合格/未通过/缺考/旷考/作弊 is failed', () {
      expect(_grade('不及格').isPassed, false);
      expect(_grade('不合格').isPassed, false);
      expect(_grade('未通过').isPassed, false);
      expect(_grade('缺考').isPassed, false);
      expect(_grade('旷考').isPassed, false);
      expect(_grade('作弊').isPassed, false);
    });

    // Unknown
    test('empty, 未录入, 缓考, -- are unknown', () {
      expect(_grade('未录入').isPassed, isNull);
      expect(_grade('缓考').isPassed, isNull);
      expect(_grade('--').isPassed, isNull);
      expect(_grade('').isPassed, isNull);
    });

    test('unrecognized text is unknown', () {
      expect(_grade('待定').isPassed, isNull);
      expect(_grade('补考').isPassed, isNull);
    });
  });

  group('EduGrade.computeWeightedGpa', () {
    test('normal weighted average', () {
      final grades = [
        _gpa(3.0, 4.0), // 12.0
        _gpa(4.0, 2.0), // 8.0
      ];
      // (12+8) / (4+2) = 20/6 = 3.333...
      final result = EduGrade.computeWeightedGpa(grades);
      expect(result, isNotNull);
      expect(result!, closeTo(3.333, 0.01));
    });

    test('single course', () {
      final grades = [_gpa(3.5, 3.0)];
      final result = EduGrade.computeWeightedGpa(grades);
      expect(result, 3.5);
    });

    test('all null gpa returns null', () {
      final grades = [
        _gpaNull(3.0),
        _gpaNull(2.0),
      ];
      final result = EduGrade.computeWeightedGpa(grades);
      expect(result, isNull);
    });

    test('zero credits excluded', () {
      final grades = [
        _gpa(4.0, 0.0), // skipped
        _gpa(3.0, 2.0), // 6.0
      ];
      final result = EduGrade.computeWeightedGpa(grades);
      expect(result, 3.0);
    });

    test('mixed gpa and non-gpa courses', () {
      final grades = [
        _gpa(4.0, 3.0), // 12.0
        _gpaNull(2.0), // skipped (no GPA)
        _gpa(2.0, 1.0), // 2.0
      ];
      // (12+2) / (3+1) = 14/4 = 3.5
      final result = EduGrade.computeWeightedGpa(grades);
      expect(result, 3.5);
    });

    test('empty list returns null', () {
      final result = EduGrade.computeWeightedGpa([]);
      expect(result, isNull);
    });

    test('all zero credits returns null', () {
      final grades = [
        _gpa(4.0, 0.0),
        _gpa(3.0, 0.0),
      ];
      final result = EduGrade.computeWeightedGpa(grades);
      expect(result, isNull);
    });
  });

  group('EduSemester', () {
    test('constants are 3 and 12', () {
      expect(EduSemester.first, 3);
      expect(EduSemester.second, 12);
    });

    test('isValid only accepts 3 and 12', () {
      expect(EduSemester.isValid(3), true);
      expect(EduSemester.isValid(12), true);
      expect(EduSemester.isValid(1), false);
      expect(EduSemester.isValid(2), false);
      expect(EduSemester.isValid(0), false);
      expect(EduSemester.isValid(-1), false);
    });

    test('displayLabel', () {
      expect(EduSemester.displayLabel(3), '第一学期');
      expect(EduSemester.displayLabel(12), '第二学期');
      expect(EduSemester.displayLabel(99), '未知学期');
    });

    test('fullLabel format', () {
      final label = EduSemester.fullLabel('2025', 3);
      expect(label, contains('2025-2026'));
      expect(label, contains('第一学期'));
    });

    test('current returns valid semester values', () {
      final cur = EduSemester.current();
      expect(EduSemester.isValid(cur.semester), true);
      expect(int.tryParse(cur.year), isNotNull);
    });

    test('buildSemesterList does not generate future semesters', () {
      final cur = EduSemester.current();
      final curYear = int.parse(cur.year);
      final list = EduSemester.buildSemesterList(2022);

      for (final s in list) {
        final y = int.parse(s.year);
        expect(y, lessThanOrEqualTo(curYear));
        if (y == curYear) {
          expect(s.semester, lessThanOrEqualTo(cur.semester));
        }
      }
    });

    test('buildSemesterList marks one item as current', () {
      final list = EduSemester.buildSemesterList(2022);
      final currentItems = list.where((s) => s.isCurrent).toList();
      expect(currentItems.length, 1);
    });

    test('buildSemesterList is sorted most recent first', () {
      final list = EduSemester.buildSemesterList(2022);
      for (int i = 0; i < list.length - 1; i++) {
        final a = list[i];
        final b = list[i + 1];
        final aY = int.parse(a.year);
        final bY = int.parse(b.year);
        // a should be more recent than b (year desc, then semester desc)
        if (aY == bY) {
          expect(a.semester, greaterThan(b.semester));
        } else {
          expect(aY, greaterThan(bY));
        }
      }
    });
  });

  group('EduGrade summary stats', () {
    test('pass/fail/unknown counts are correct', () {
      final grades = [
        _grade('90'), // pass
        _grade('55'), // fail
        _grade('优秀'), // pass
        _grade('合格'), // pass
        _grade('不及格'), // fail
        _grade('缓考'), // unknown
        _grade('--'), // unknown
      ];
      final passed = grades.where((g) => g.isPassed == true).length;
      final failed = grades.where((g) => g.isPassed == false).length;
      final unknown = grades.where((g) => g.isPassed == null).length;

      expect(passed, 3); // 90, 优秀, 合格
      expect(failed, 2); // 55, 不及格
      expect(unknown, 2); // 缓考, --
    });
  });

  group('GradeStableKey', () {
    test('prefers studentGradeId when available', () {
      const g = EduGrade(
        name: '微积分',
        studentGradeId: 'SGID_123',
        courseId: 'CID_456',
        courseCode: 'MATH101',
        classId: 'CLASS_1',
        displayGrade: '90',
        credits: 4,
        gpa: 4.0,
        isDegree: true,
      );
      expect(GradeStableKey.of(g), 'sgid:SGID_123');
    });

    test('falls back to courseId when studentGradeId is empty', () {
      const g = EduGrade(
        name: '微积分',
        courseId: 'CID_456',
        courseCode: 'MATH101',
        classId: 'CLASS_1',
        displayGrade: '90',
        credits: 4,
        gpa: 4.0,
        isDegree: true,
      );
      expect(GradeStableKey.of(g), 'cid:CID_456');
    });

    test('falls back to courseCode + classId when courseId is empty', () {
      const g = EduGrade(
        name: '大学英语',
        courseCode: 'ENG201',
        classId: 'CLASS_2',
        displayGrade: '85',
        credits: 2,
        gpa: 3.5,
        isDegree: false,
      );
      expect(GradeStableKey.of(g), 'code_class:ENG201_CLASS_2');
    });

    test('falls back to name + examType as ultimate fallback', () {
      const g = EduGrade(
        name: '体育',
        examType: '正常考试',
        displayGrade: '80',
        credits: 1,
        gpa: 3.0,
        isDegree: false,
      );
      expect(GradeStableKey.of(g), 'name_exam:体育_正常考试');
    });
  });

  group('GradeDiff', () {
    test('detects newly added courses', () {
      final oldGrades = [
        const EduGrade(
          name: '高数',
          courseId: 'C1',
          displayGrade: '86',
          credits: 4,
          gpa: 3.6,
          isDegree: true,
        ),
      ];
      final newGrades = [
        const EduGrade(
          name: '高数',
          courseId: 'C1',
          displayGrade: '86',
          credits: 4,
          gpa: 3.6,
          isDegree: true,
        ),
        const EduGrade(
          name: '数据库原理',
          courseId: 'C2',
          displayGrade: '88',
          credits: 3,
          gpa: 3.8,
          isDegree: true,
        ),
      ];
      final diff = GradeDiff.compute(oldGrades, newGrades);
      expect(diff.hasChanges, isTrue);
      expect(diff.added.length, 1);
      expect(diff.added.first.name, '数据库原理');
      expect(diff.changed, isEmpty);
      expect(diff.removed, isEmpty);
    });

    test('treats course changing from unscored (--/未录入) to scored as added', () {
      final oldGrades = [
        const EduGrade(
          name: '高等数学',
          courseId: 'C1',
          displayGrade: '--',
          credits: 4,
          gpa: null,
          isDegree: true,
        ),
      ];
      final newGrades = [
        const EduGrade(
          name: '高等数学',
          courseId: 'C1',
          displayGrade: '87',
          credits: 4,
          gpa: 3.7,
          isDegree: true,
        ),
      ];
      final diff = GradeDiff.compute(oldGrades, newGrades);
      expect(diff.hasChanges, isTrue);
      expect(diff.added.length, 1);
      expect(diff.added.first.name, '高等数学');
      expect(diff.added.first.displayGrade, '87');
      expect(diff.changed, isEmpty);
    });

    test('detects grade modification (82 -> 85) as changed', () {
      final oldGrades = [
        const EduGrade(
          name: '高等数学',
          courseId: 'C1',
          displayGrade: '82',
          credits: 4,
          gpa: 3.2,
          isDegree: true,
        ),
      ];
      final newGrades = [
        const EduGrade(
          name: '高等数学',
          courseId: 'C1',
          displayGrade: '85',
          credits: 4,
          gpa: 3.5,
          isDegree: true,
        ),
      ];
      final diff = GradeDiff.compute(oldGrades, newGrades);
      expect(diff.hasChanges, isTrue);
      expect(diff.added, isEmpty);
      expect(diff.changed.length, 1);
      expect(diff.changed.first.oldGrade.displayGrade, '82');
      expect(diff.changed.first.newGrade.displayGrade, '85');
    });

    test('detects credits modification as changed', () {
      final oldGrades = [
        const EduGrade(
          name: '物理实验',
          courseId: 'C1',
          displayGrade: '80',
          credits: 1.0,
          gpa: 3.0,
          isDegree: false,
        ),
      ];
      final newGrades = [
        const EduGrade(
          name: '物理实验',
          courseId: 'C1',
          displayGrade: '80',
          credits: 1.5,
          gpa: 3.0,
          isDegree: false,
        ),
      ];
      final diff = GradeDiff.compute(oldGrades, newGrades);
      expect(diff.hasChanges, isTrue);
      expect(diff.changed.length, 1);
      expect(diff.changed.first.reason, contains('学分修正'));
    });

    test('detects removed courses', () {
      final oldGrades = [
        const EduGrade(
          name: '已退选课',
          courseId: 'C_DROP',
          displayGrade: '80',
          credits: 2,
          gpa: 3.0,
          isDegree: false,
        ),
      ];
      final newGrades = <EduGrade>[];
      final diff = GradeDiff.compute(oldGrades, newGrades);
      expect(diff.hasChanges, isTrue);
      expect(diff.removed.length, 1);
      expect(diff.removed.first.name, '已退选课');
    });

    test('returns hasChanges = false when grades are identical', () {
      final grades = [
        const EduGrade(
          name: '数据结构',
          courseId: 'C1',
          displayGrade: '90',
          credits: 3,
          gpa: 4.0,
          isDegree: true,
        ),
      ];
      final diff = GradeDiff.compute(grades, grades);
      expect(diff.hasChanges, isFalse);
      expect(diff.added, isEmpty);
      expect(diff.changed, isEmpty);
      expect(diff.removed, isEmpty);
    });
  });
}

/// Helper: create an EduGrade with a given displayGrade and default other fields.
EduGrade _grade(String displayGrade) {
  return EduGrade(
    name: '测试课程',
    displayGrade: displayGrade,
    credits: 2.0,
    gpa: null,
    isDegree: false,
  );
}

/// Helper: create an EduGrade with a specific GPA.
EduGrade _gpa(double gpa, double credits) {
  return EduGrade(
    name: '课程',
    displayGrade: '80',
    credits: credits,
    gpa: gpa,
    isDegree: false,
  );
}

/// Helper: create an EduGrade with no GPA.
EduGrade _gpaNull(double credits) {
  return EduGrade(
    name: '课程',
    displayGrade: '合格',
    credits: credits,
    gpa: null,
    isDegree: false,
  );
}
