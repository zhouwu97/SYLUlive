/// 教务客户端能力声明。
///
/// 声明本地 Dart 实现支持的功能范围。
final class AcademicCapabilities {
  const AcademicCapabilities({
    required this.supportsProfile,
    required this.supportsCourses,
    required this.supportsGrades,
    required this.supportsGradeDetail,
    required this.supportsAcademicSituation,
    required this.supportsCreditRequirements,
  });

  /// 本地 Dart 实现的能力。
  const AcademicCapabilities.local()
      : supportsProfile = true,
        supportsCourses = true,
        supportsGrades = true,
        supportsGradeDetail = true,
        supportsAcademicSituation = true,
        supportsCreditRequirements = true;

  final bool supportsProfile;
  final bool supportsCourses;
  final bool supportsGrades;
  final bool supportsGradeDetail;
  final bool supportsAcademicSituation;
  final bool supportsCreditRequirements;

  Map<String, bool> toJson() => {
        'supportsProfile': supportsProfile,
        'supportsCourses': supportsCourses,
        'supportsGrades': supportsGrades,
        'supportsGradeDetail': supportsGradeDetail,
        'supportsAcademicSituation': supportsAcademicSituation,
        'supportsCreditRequirements': supportsCreditRequirements,
      };

  @override
  String toString() => 'AcademicCapabilities('
      'profile: $supportsProfile, '
      'courses: $supportsCourses, '
      'grades: $supportsGrades, '
      'gradeDetail: $supportsGradeDetail, '
      'academicSituation: $supportsAcademicSituation, '
      'creditRequirements: $supportsCreditRequirements)';
}
