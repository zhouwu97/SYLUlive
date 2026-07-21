class EduAcademicSituation {
  final bool success;
  final String sourceKind;
  final String sourceUrl;
  final String parserVersion;
  final DateTime? capturedAt;
  final DateTime? officialUpdatedAt;
  final String? structureSignature;
  final double? allGpa;
  final double? degreeGpa;
  final int totalCourses;
  final int passedCourses;
  final int failedCourses;
  final int notStartedCourses;
  final int inProgressCourses;
  final int degreeTotalCourses;
  final int degreePassedCourses;
  final int degreeFailedCourses;
  final int degreeNotStartedCourses;
  final int degreeInProgressCourses;
  final String coursesStatus;
  final List<EduAcademicCourse> courses;
  final String? errorCode;
  final String? message;

  const EduAcademicSituation({
    required this.success,
    required this.sourceKind,
    required this.sourceUrl,
    required this.parserVersion,
    required this.capturedAt,
    required this.officialUpdatedAt,
    required this.structureSignature,
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
    required this.coursesStatus,
    required this.courses,
    required this.errorCode,
    required this.message,
  });

  factory EduAcademicSituation.fromJson(Map<String, dynamic> json) {
    return EduAcademicSituation(
      success: json['success'] == true,
      sourceKind: (json['source_kind'] ?? '').toString(),
      sourceUrl: (json['source_url'] ?? '').toString(),
      parserVersion: (json['parser_version'] ?? '').toString(),
      capturedAt: _parseDateTime(json['captured_at'] ?? json['updated_at']),
      officialUpdatedAt: _parseDateTime(json['official_updated_at']),
      structureSignature: _emptyToNull(json['structure_signature']),
      allGpa: _tryParseDouble(json['all_gpa']),
      degreeGpa: _tryParseDouble(json['degree_gpa']),
      totalCourses: _parseInt(json['total_courses']),
      passedCourses: _parseInt(json['passed_courses']),
      failedCourses: _parseInt(json['failed_courses']),
      notStartedCourses: _parseInt(json['not_started_courses']),
      inProgressCourses: _parseInt(json['in_progress_courses']),
      degreeTotalCourses: _parseInt(json['degree_total_courses']),
      degreePassedCourses: _parseInt(json['degree_passed_courses']),
      degreeFailedCourses: _parseInt(json['degree_failed_courses']),
      degreeNotStartedCourses: _parseInt(json['degree_not_started_courses']),
      degreeInProgressCourses: _parseInt(json['degree_in_progress_courses']),
      coursesStatus: (json['courses_status'] ?? 'not_present').toString(),
      courses: (json['courses'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => EduAcademicCourse.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      errorCode: _emptyToNull(json['error_code']),
      message: _emptyToNull(json['message']),
    );
  }
}

class EduAcademicCourse {
  final String? studyStatus;
  final String? academicYear;
  final String? semester;
  final String courseCode;
  final String courseName;
  final String? hours;
  final String? courseNature;
  final double credits;
  final String? courseCategory;
  final String? maxGrade;
  final double? gpa;
  final String? grade;
  final String? makeupGrade;
  final String? retakeGrade;
  final String? suggestedYear;
  final String? suggestedSemester;
  final String? importantNatureCount;
  final bool isDegree;
  final bool hasRetake;
  final String? effectiveGrade;
  final bool? effectivePassed;

  const EduAcademicCourse({
    required this.studyStatus,
    required this.academicYear,
    required this.semester,
    required this.courseCode,
    required this.courseName,
    required this.hours,
    required this.courseNature,
    required this.credits,
    required this.courseCategory,
    required this.maxGrade,
    required this.gpa,
    required this.grade,
    required this.makeupGrade,
    required this.retakeGrade,
    required this.suggestedYear,
    required this.suggestedSemester,
    required this.importantNatureCount,
    required this.isDegree,
    required this.hasRetake,
    required this.effectiveGrade,
    required this.effectivePassed,
  });

  factory EduAcademicCourse.fromJson(Map<String, dynamic> json) {
    return EduAcademicCourse(
      studyStatus: _emptyToNull(json['study_status']),
      academicYear: _emptyToNull(json['academic_year']),
      semester: _emptyToNull(json['semester']),
      courseCode: (json['course_code'] ?? '').toString(),
      courseName: (json['course_name'] ?? '').toString(),
      hours: _emptyToNull(json['hours']),
      courseNature: _emptyToNull(json['course_nature']),
      credits: _parseDouble(json['credits']),
      courseCategory: _emptyToNull(json['course_category']),
      maxGrade: _emptyToNull(json['max_grade']),
      gpa: _tryParseDouble(json['gpa']),
      grade: _emptyToNull(json['grade']),
      makeupGrade: _emptyToNull(json['makeup_grade']),
      retakeGrade: _emptyToNull(json['retake_grade']),
      suggestedYear: _emptyToNull(json['suggested_year']),
      suggestedSemester: _emptyToNull(json['suggested_semester']),
      importantNatureCount: _emptyToNull(json['important_nature_count']),
      isDegree: json['is_degree'] == true ||
          json['is_degree'] == 1 ||
          json['is_degree'] == '1' ||
          json['is_degree'] == '是',
      hasRetake: json['has_retake'] == true ||
          json['has_retake'] == 1 ||
          json['has_retake'] == '1',
      effectiveGrade: _emptyToNull(json['effective_grade']),
      effectivePassed: _parseBoolNullable(json['effective_passed']),
    );
  }

  String get displayStatus {
    if (hasRetake && effectivePassed == true) return '重修通过';
    if (studyStatus != null && studyStatus!.trim().isNotEmpty) {
      return studyStatus!;
    }
    if (effectivePassed == true) return '已通过';
    if (effectivePassed == false) return '未通过';
    return '未知';
  }

  String get displayGrade {
    return effectiveGrade ??
        maxGrade ??
        retakeGrade ??
        makeupGrade ??
        grade ??
        '--';
  }
}

double _parseDouble(dynamic value) => _tryParseDouble(value) ?? 0;

double? _tryParseDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int _parseInt(dynamic value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}

String? _emptyToNull(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty || text == '--' || text == '—' || text == '-') return null;
  return text;
}

DateTime? _parseDateTime(dynamic value) {
  final text = _emptyToNull(value);
  return text == null ? null : DateTime.tryParse(text);
}

bool? _parseBoolNullable(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value.toString().trim().toLowerCase();
  if (text == 'true' || text == '1' || text == '是') return true;
  if (text == 'false' || text == '0' || text == '否') return false;
  return null;
}
