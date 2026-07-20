import '../personal_data/models/academic_records.dart';

class CourseCalculationEvidence {
  const CourseCalculationEvidence({
    required this.courseId,
    required this.courseName,
    required this.semesterId,
    required this.credit,
    required this.reason,
  });

  final String courseId;
  final String courseName;
  final String semesterId;
  final double credit;
  final String reason;
}

class GpaResult {
  GpaResult({
    required this.formulaVersion,
    required this.gpa,
    required this.includedCredits,
    required List<CourseCalculationEvidence> includedCourses,
    required List<CourseCalculationEvidence> excludedCourses,
    required List<String> unparseableCourses,
    required this.missingCreditCount,
  })  : includedCourses = List.unmodifiable(includedCourses),
        excludedCourses = List.unmodifiable(excludedCourses),
        unparseableCourses = List.unmodifiable(unparseableCourses);

  final String formulaVersion;
  final double? gpa;
  final double includedCredits;
  final List<CourseCalculationEvidence> includedCourses;
  final List<CourseCalculationEvidence> excludedCourses;
  final List<String> unparseableCourses;
  final int missingCreditCount;
}

class CreditSummary {
  const CreditSummary({
    required this.attemptedCredits,
    required this.passedCredits,
    required this.failedCredits,
    required this.requiredFailedCredits,
    required this.unknownCredits,
  });

  final double attemptedCredits;
  final double passedCredits;
  final double failedCredits;
  final double requiredFailedCredits;
  final double unknownCredits;
}

class FailedCourseSummary {
  FailedCourseSummary({
    required List<CourseGradeRecord> failedCourses,
    required List<CourseGradeRecord> unknownCourses,
  })  : failedCourses = List.unmodifiable(failedCourses),
        unknownCourses = List.unmodifiable(unknownCourses);

  final List<CourseGradeRecord> failedCourses;
  final List<CourseGradeRecord> unknownCourses;
}

class SemesterTrendPoint {
  const SemesterTrendPoint({required this.semesterId, required this.gpa});
  final String semesterId;
  final double? gpa;
}

class SemesterTrend {
  SemesterTrend(List<SemesterTrendPoint> points)
      : points = List.unmodifiable(points);
  final List<SemesterTrendPoint> points;
}

class AcademicCalculationEngine {
  static const String formulaVersion = 'sylu-gpa-v1';

  GpaResult calculateGpa(List<CourseGradeRecord> courses) {
    final selected = _latestBestAttempts(courses);
    final included = <CourseCalculationEvidence>[];
    final excluded = <CourseCalculationEvidence>[];
    final unparseable = <String>[];
    var weighted = 0.0;
    var credits = 0.0;
    var missingCreditCount = 0;

    for (final course in selected) {
      final score = _normalizedScore(course);
      if (course.credit <= 0) {
        missingCreditCount++;
        excluded.add(_evidence(course, '缺少有效学分'));
      } else if (score == null) {
        unparseable.add(course.courseName);
        excluded.add(_evidence(course, '成绩无法解析'));
      } else {
        weighted += _gradePoint(score) * course.credit;
        credits += course.credit;
        included.add(_evidence(course, '采用同课程最佳有效成绩'));
      }
    }
    return GpaResult(
      formulaVersion: formulaVersion,
      gpa: credits == 0 ? null : weighted / credits,
      includedCredits: credits,
      includedCourses: included,
      excludedCourses: excluded,
      unparseableCourses: unparseable,
      missingCreditCount: missingCreditCount,
    );
  }

  CreditSummary calculateCredits(List<CourseGradeRecord> courses) {
    var attempted = 0.0;
    var passed = 0.0;
    var failed = 0.0;
    var requiredFailed = 0.0;
    var unknown = 0.0;
    for (final course in _latestBestAttempts(courses)) {
      if (course.credit <= 0) continue;
      attempted += course.credit;
      switch (_passed(course)) {
        case true:
          passed += course.credit;
        case false:
          failed += course.credit;
          if (course.nature == CourseNature.requiredCourse) {
            requiredFailed += course.credit;
          }
        case null:
          unknown += course.credit;
      }
    }
    return CreditSummary(
      attemptedCredits: attempted,
      passedCredits: passed,
      failedCredits: failed,
      requiredFailedCredits: requiredFailed,
      unknownCredits: unknown,
    );
  }

  FailedCourseSummary calculateFailures(List<CourseGradeRecord> courses) {
    final failed = <CourseGradeRecord>[];
    final unknown = <CourseGradeRecord>[];
    for (final course in _latestBestAttempts(courses)) {
      final passed = _passed(course);
      if (passed == false) failed.add(course);
      if (passed == null) unknown.add(course);
    }
    return FailedCourseSummary(failedCourses: failed, unknownCourses: unknown);
  }

  SemesterTrend calculateTrend(List<CourseGradeRecord> courses) {
    final semesterIds = courses.map((item) => item.semesterId).toSet().toList()
      ..sort();
    return SemesterTrend(
      semesterIds
          .map(
            (id) => SemesterTrendPoint(
              semesterId: id,
              gpa: calculateGpa(
                courses.where((item) => item.semesterId == id).toList(),
              ).gpa,
            ),
          )
          .toList(),
    );
  }

  List<CourseGradeRecord> _latestBestAttempts(List<CourseGradeRecord> courses) {
    final grouped = <String, List<CourseGradeRecord>>{};
    for (final course in courses) {
      grouped
          .putIfAbsent(course.courseId, () => <CourseGradeRecord>[])
          .add(course);
    }
    return grouped.values.map((attempts) {
      attempts.sort((left, right) {
        final leftScore = _normalizedScore(left) ?? -1;
        final rightScore = _normalizedScore(right) ?? -1;
        final scoreOrder = rightScore.compareTo(leftScore);
        return scoreOrder != 0
            ? scoreOrder
            : right.semesterId.compareTo(left.semesterId);
      });
      return attempts.first;
    }).toList();
  }

  bool? _passed(CourseGradeRecord course) {
    final score = _normalizedScore(course);
    if (score != null) return score >= 60;
    final text = course.gradeText?.trim() ?? '';
    if (const <String>{'优秀', '良好', '中等', '及格', '合格', '通过'}.contains(text)) {
      return true;
    }
    if (const <String>{'不及格', '不合格', '未通过', '缺考', '旷考', '作弊'}.contains(text)) {
      return false;
    }
    return null;
  }

  double? _normalizedScore(CourseGradeRecord course) {
    if (course.score != null && course.score! >= 0 && course.score! <= 100) {
      return course.score;
    }
    final numeric = double.tryParse(course.gradeText?.trim() ?? '');
    if (numeric != null && numeric >= 0 && numeric <= 100) return numeric;
    return switch (course.gradeText?.trim()) {
      '优秀' => 95,
      '良好' => 85,
      '中等' => 75,
      '及格' || '合格' || '通过' => 65,
      '不及格' || '不合格' || '未通过' => 0,
      _ => null,
    };
  }

  double _gradePoint(double score) => switch (score) {
        >= 90 => 4.0,
        >= 85 => 3.7,
        >= 82 => 3.3,
        >= 78 => 3.0,
        >= 75 => 2.7,
        >= 72 => 2.3,
        >= 68 => 2.0,
        >= 64 => 1.5,
        >= 60 => 1.0,
        _ => 0.0,
      };

  CourseCalculationEvidence _evidence(
          CourseGradeRecord course, String reason) =>
      CourseCalculationEvidence(
        courseId: course.courseId,
        courseName: course.courseName,
        semesterId: course.semesterId,
        credit: course.credit,
        reason: reason,
      );
}
