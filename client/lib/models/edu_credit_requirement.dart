/// 官方学分要求模块的数据模型。
///
/// 对应 Python 教务服务返回的 credit-requirement-v2 结构。

class EduCreditRequirementOverview {
  final bool success;
  final String sourceKind;
  final String sourceUrl;
  final String parserVersion;
  final DateTime? capturedAt;
  final String? structureSignature;

  final String? collegeName;
  final String? enrollmentGrade;
  final String? majorName;

  final List<EduCreditRequirementModule> modules;
  final List<EduRequirementCourse> improvementCourses;

  final String status;
  final String? errorCode;
  final String? message;

  const EduCreditRequirementOverview({
    required this.success,
    required this.sourceKind,
    required this.sourceUrl,
    required this.parserVersion,
    required this.capturedAt,
    required this.structureSignature,
    required this.collegeName,
    required this.enrollmentGrade,
    required this.majorName,
    required this.modules,
    required this.improvementCourses,
    required this.status,
    required this.errorCode,
    required this.message,
  });

  factory EduCreditRequirementOverview.fromJson(Map<String, dynamic> json) {
    return EduCreditRequirementOverview(
      success: json['success'] == true,
      sourceKind: (json['source_kind'] ?? '').toString(),
      sourceUrl: (json['source_url'] ?? '').toString(),
      parserVersion: (json['parser_version'] ?? '').toString(),
      capturedAt: _parseDateTime(json['captured_at']),
      structureSignature: _emptyToNull(json['structure_signature']),
      collegeName: _emptyToNull(
        (json['query_context'] as Map?)?['college_name'],
      ),
      enrollmentGrade: _emptyToNull(
        (json['query_context'] as Map?)?['enrollment_grade'],
      ),
      majorName: _emptyToNull(
        (json['query_context'] as Map?)?['major_name'],
      ),
      modules: (json['modules'] as List? ?? const [])
          .whereType<Map>()
          .map(
              (m) => EduCreditRequirementModule.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      improvementCourses: (json['improvement_courses'] as List? ?? const [])
          .whereType<Map>()
          .map((m) =>
              EduRequirementCourse.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      status: (json['status'] ?? 'unknown').toString(),
      errorCode: _emptyToNull(json['error_code']),
      message: _emptyToNull(json['message']),
    );
  }
}

class EduCreditRequirementModule {
  final String id;
  final String name;
  final String moduleType;

  final double? requiredCredits;
  final int? requiredCourseCount;
  final double earnedCredits;
  final int completedCourseCount;

  final String status;
  final bool isOptional;
  final List<EduRequirementCourse> courses;

  const EduCreditRequirementModule({
    required this.id,
    required this.name,
    required this.moduleType,
    required this.requiredCredits,
    required this.requiredCourseCount,
    required this.earnedCredits,
    required this.completedCourseCount,
    required this.status,
    required this.isOptional,
    required this.courses,
  });

  factory EduCreditRequirementModule.fromJson(Map<String, dynamic> json) {
    return EduCreditRequirementModule(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      moduleType: (json['module_type'] ?? 'required').toString(),
      requiredCredits: _tryParseDouble(json['required_credits']),
      requiredCourseCount: _tryParseInt(json['required_course_count']),
      earnedCredits: _tryParseDouble(json['earned_credits']) ?? 0,
      completedCourseCount: _parseInt(json['completed_course_count']),
      status: (json['status'] ?? 'unknown').toString(),
      isOptional: json['is_optional'] == true,
      courses: (json['courses'] as List? ?? const [])
          .whereType<Map>()
          .map((m) =>
              EduRequirementCourse.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }

  /// 进度比例 [0.0, 1.0]，即使已获学分超过要求也只到 1.0。
  double get progress {
    final req = requiredCredits;
    if (req == null || req <= 0) return 0.0;
    return (earnedCredits / req).clamp(0.0, 1.0);
  }

  /// 是否有最低学分要求。
  bool get hasRequiredCredits => requiredCredits != null && requiredCredits! > 0;

  /// 超出/不足学分描述（不含单位）。
  String get creditDeltaText {
    final req = requiredCredits;
    if (req == null || req <= 0) return '';
    final delta = earnedCredits - req;
    if (delta >= 0) {
      return '已超过最低要求 ${_formatCredits(delta)} 学分';
    }
    return '距离最低要求还差 ${_formatCredits(delta.abs())} 学分';
  }

  /// 更人性化的状态文本。
  String get statusLabel {
    switch (status) {
      case 'completed':
        return '已满足';
      case 'in_progress':
        return '进行中';
      case 'shortfall':
        return '待补足';
      case 'unknown':
        return '状态未知';
      default:
        return status;
    }
  }
}

class EduRequirementCourse {
  final String courseCode;
  final String courseName;
  final double credits;

  final String? suggestedYear;
  final String? suggestedSemester;
  final String? actualYear;
  final String? actualSemester;

  final String? courseNature;
  final String? grade;
  final String? rawStatus;
  final String? remark;

  final bool? completed;

  const EduRequirementCourse({
    required this.courseCode,
    required this.courseName,
    required this.credits,
    required this.suggestedYear,
    required this.suggestedSemester,
    required this.actualYear,
    required this.actualSemester,
    required this.courseNature,
    required this.grade,
    required this.rawStatus,
    required this.remark,
    required this.completed,
  });

  factory EduRequirementCourse.fromJson(Map<String, dynamic> json) {
    return EduRequirementCourse(
      courseCode: (json['course_code'] ?? '').toString(),
      courseName: (json['course_name'] ?? '').toString(),
      credits: _tryParseDouble(json['credits']) ?? 0,
      suggestedYear: _emptyToNull(json['suggested_year']),
      suggestedSemester: _emptyToNull(json['suggested_semester']),
      actualYear: _emptyToNull(json['actual_year']),
      actualSemester: _emptyToNull(json['actual_semester']),
      courseNature: _emptyToNull(json['course_nature']),
      grade: _emptyToNull(json['grade']),
      rawStatus: _emptyToNull(json['raw_status']),
      remark: _emptyToNull(json['remark']),
      completed: _parseBoolNullable(json['completed']),
    );
  }

  /// 学分文本。
  String get creditsText => _formatCredits(credits);

  /// 实际修读学期文本。
  String get actualTermText {
    if (actualYear == null && actualSemester == null) return '';
    final year = actualYear ?? '';
    final sem = _semesterLabel(actualSemester);
    if (year.isEmpty) return sem;
    if (sem.isEmpty) return year;
    return '$year $sem';
  }

  /// 建议修读学期文本。
  String get suggestedTermText {
    if (suggestedYear == null && suggestedSemester == null) return '';
    final year = suggestedYear ?? '';
    final sem = _semesterLabel(suggestedSemester);
    if (year.isEmpty) return sem;
    if (sem.isEmpty) return year;
    return '$year $sem';
  }

  /// 是否应该显示建议修读学期。
  bool get showSuggestedTerm {
    // 尚未修读
    if (completed == false || rawStatus == '未修读') return true;
    // 建议学期与实际修读学期不同
    if (suggestedTermText.isNotEmpty &&
        actualTermText.isNotEmpty &&
        suggestedTermText != actualTermText) {
      return true;
    }
    // 实际学期为空但有建议学期
    if (suggestedTermText.isNotEmpty && actualTermText.isEmpty) return true;
    return false;
  }

  /// 成绩文本。
  String get gradeText {
    return grade ?? '--';
  }

  /// 状态文本。
  String get statusText {
    if (rawStatus != null && rawStatus!.isNotEmpty) return rawStatus!;
    if (completed == true) return '已修读';
    if (completed == false) return '未修读';
    return '';
  }
}

String? _emptyToNull(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty || text == '--' || text == '—' || text == '-') return null;
  return text;
}

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

int? _tryParseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  final parsed = int.tryParse(value.toString());
  return parsed;
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

String _formatCredits(double credits) {
  return credits.toStringAsFixed(
    credits.truncateToDouble() == credits ? 0 : 1,
  );
}

String _semesterLabel(String? semValue) {
  if (semValue == null) return '';
  switch (semValue.trim()) {
    case '3':
    case '1':
      return '第一学期';
    case '12':
    case '2':
      return '第二学期';
    default:
      return semValue;
  }
}
