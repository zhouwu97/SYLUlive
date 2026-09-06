/// 学业情况数据模型。
///
/// 对应 Python 端的 AcademicSituationResponse。
final class AcademicSituation {
  const AcademicSituation({
    required this.success,
    required this.allGpa,
    required this.degreeGpa,
    required this.totalCourses,
    required this.passedCourses,
    required this.failedCourses,
    required this.notStartedCourses,
    required this.inProgressCourses,
    required this.degreeTotalCourses,
    required this.degreePassedCourses,
    required this.degreeFailedCourses,
    required this.degreeNotStartedCourses,
    required this.degreeInProgressCourses,
    required this.courses,
    required this.coursesStatus,
    this.message,
    this.errorCode,
  });

  final bool success;
  final double? allGpa;
  final double? degreeGpa;
  final int? totalCourses;
  final int? passedCourses;
  final int? failedCourses;
  final int? notStartedCourses;
  final int? inProgressCourses;
  final int? degreeTotalCourses;
  final int? degreePassedCourses;
  final int? degreeFailedCourses;
  final int? degreeNotStartedCourses;
  final int? degreeInProgressCourses;
  final List<AcademicCourse> courses;
  final String coursesStatus;
  final String? message;
  final String? errorCode;

  Map<String, Object?> toJson() => {
        'success': success,
        'all_gpa': allGpa,
        'degree_gpa': degreeGpa,
        'total_courses': totalCourses,
        'passed_courses': passedCourses,
        'failed_courses': failedCourses,
        'not_started_courses': notStartedCourses,
        'in_progress_courses': inProgressCourses,
        'degree_total_courses': degreeTotalCourses,
        'degree_passed_courses': degreePassedCourses,
        'degree_failed_courses': degreeFailedCourses,
        'degree_not_started_courses': degreeNotStartedCourses,
        'degree_in_progress_courses': degreeInProgressCourses,
        'courses': courses.map((c) => c.toJson()).toList(),
        'courses_status': coursesStatus,
        'message': message,
        'error_code': errorCode,
      };

  @override
  String toString() => 'AcademicSituation('
      'success: $success, '
      'allGpa: $allGpa, '
      'degreeGpa: $degreeGpa, '
      'totalCourses: $totalCourses, '
      'coursesStatus: $coursesStatus)';
}

/// 学业情况中的课程记录。
final class AcademicCourse {
  const AcademicCourse({
    required this.courseName,
    required this.courseId,
    required this.credits,
    required this.status,
    required this.effectiveGrade,
    required this.effectivePassed,
    required this.isDegree,
    required this.hasRetake,
    this.maxGrade,
    this.gpa,
    this.courseCategory,
    this.courseNature,
  });

  final String courseName;
  final String courseId;
  final double credits;
  final String status;
  final String effectiveGrade;
  final bool effectivePassed;
  final bool isDegree;
  final bool hasRetake;
  final String? maxGrade;
  final double? gpa;
  final String? courseCategory;
  final String? courseNature;

  Map<String, Object?> toJson() => {
        'course_name': courseName,
        'course_id': courseId,
        'credits': credits,
        'status': status,
        'effective_grade': effectiveGrade,
        'effective_passed': effectivePassed,
        'is_degree': isDegree,
        'has_retake': hasRetake,
        'max_grade': maxGrade,
        'gpa': gpa,
        'course_category': courseCategory,
        'course_nature': courseNature,
      };
}
