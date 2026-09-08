/// 学分要求数据模型。
///
/// 对应 Python 端的 CreditRequirementResponse。
final class CreditRequirement {
  const CreditRequirement({
    required this.success,
    required this.status,
    required this.modules,
    required this.improvementCourses,
    this.message,
    this.errorCode,
  });

  final bool success;
  final String status;
  final List<CreditModule> modules;
  final List<ImprovementCourse> improvementCourses;
  final String? message;
  final String? errorCode;

  Map<String, Object?> toJson() => {
        'success': success,
        'status': status,
        'modules': modules.map((m) => m.toJson()).toList(),
        'improvement_courses':
            improvementCourses.map((c) => c.toJson()).toList(),
        'message': message,
        'error_code': errorCode,
      };

  @override
  String toString() => 'CreditRequirement('
      'success: $success, '
      'status: $status, '
      'modules: ${modules.length}, '
      'improvementCourses: ${improvementCourses.length})';
}

/// 学分要求模块。
final class CreditModule {
  const CreditModule({
    required this.name,
    required this.requiredCredits,
    required this.earnedCredits,
    required this.status,
    required this.courses,
    this.requiredCourseCount,
  });

  final String name;
  final double? requiredCredits;
  final double earnedCredits;
  final String status;
  final List<ModuleCourse> courses;
  final int? requiredCourseCount;

  Map<String, Object?> toJson() => {
        'id': name,
        'module_type': name.contains('选') ? 'elective' : 'required',
        'is_optional': name.contains('选'),
        'completed_course_count':
            courses.where((c) => c.completed == true).length,
        'name': name,
        'required_credits': requiredCredits,
        'earned_credits': earnedCredits,
        'status': status,
        'courses': courses.map((c) => c.toJson()).toList(),
        'required_course_count': requiredCourseCount,
      };
}

/// 模块内的课程。
final class ModuleCourse {
  const ModuleCourse({
    required this.courseId,
    required this.courseName,
    required this.credits,
    required this.grade,
    required this.status,
    this.suggestedYear,
    this.suggestedSemester,
    this.actualYear,
    this.actualSemester,
  });

  final String courseId;
  final String courseName;
  final double credits;
  final String grade;
  final String status;
  final String? suggestedYear;
  final String? suggestedSemester;
  final String? actualYear;
  final String? actualSemester;

  bool? get completed => status == '已选'
      ? null
      : status == '通过' || status == '课程替代' || status == '已修读';

  Map<String, Object?> toJson() => {
        'course_id': courseId,
        'course_code': courseId,
        'raw_status': status,
        'completed': completed,
        'course_name': courseName,
        'credits': credits,
        'grade': grade,
        'status': status,
        'suggested_year': suggestedYear,
        'suggested_semester': suggestedSemester,
        'actual_year': actualYear,
        'actual_semester': actualSemester,
      };
}

/// 提高课程。
final class ImprovementCourse {
  const ImprovementCourse({
    required this.courseId,
    required this.courseName,
    required this.credits,
    required this.grade,
    required this.status,
  });

  final String courseId;
  final String courseName;
  final double credits;
  final String grade;
  final String status;

  bool? get completed => status == '已选'
      ? null
      : status == '通过' || status == '课程替代' || status == '已修读';

  Map<String, Object?> toJson() => {
        'course_id': courseId,
        'course_code': courseId,
        'raw_status': status,
        'completed': completed,
        'course_name': courseName,
        'credits': credits,
        'grade': grade,
        'status': status,
      };
}
