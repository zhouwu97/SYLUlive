/// Typed grade model — replaces raw Map<String, dynamic> in grade display code.
class EduGrade {
  final String name; // course name
  final String classId; // teaching class id
  final String studentGradeId; // opaque edu-system token for grade details
  final String courseId; // stable course id, when provided by the edu system
  final String courseCode; // course code, when provided by the edu system
  final String
      displayGrade; // original grade text: "64.7", "优秀", "良好", "--", etc.
  final double credits; // course credits, default 0
  final double? gpa; // nullable — pass/fail courses have no GPA
  final String? teacher;
  final double? gradePoints; // credits × GPA
  final double? fraction; // numeric total score when provided
  final String? examType; // 正常考试 / 补考 / 重修
  final String? courseCategory; // 主修课程 / 重修课程等
  final String? assessmentMethod; // 考试 / 考查
  final bool isDegree; // is this a degree course

  const EduGrade({
    required this.name,
    this.classId = '',
    this.studentGradeId = '',
    this.courseId = '',
    this.courseCode = '',
    required this.displayGrade,
    required this.credits,
    required this.gpa,
    this.teacher,
    this.gradePoints,
    this.fraction,
    this.examType,
    this.courseCategory,
    this.assessmentMethod,
    required this.isDegree,
  });

  factory EduGrade.fromJson(Map<String, dynamic> json) {
    return EduGrade(
      name: (json['name'] ?? '').toString(),
      classId: (json['class_id'] ?? '').toString(),
      studentGradeId: (json['student_grade_id'] ?? '').toString(),
      courseId: (json['course_id'] ?? '').toString(),
      courseCode: (json['course_code'] ?? '').toString(),
      displayGrade: (json['grade'] ?? '--').toString(),
      credits: _parseDouble(json['credits']),
      gpa: _tryParseDoubleNullable(json['gpa']),
      teacher: _emptyToNull(json['teacher']),
      gradePoints: _tryParseDoubleNullable(json['grade_points']),
      fraction: _tryParseDoubleNullable(json['fraction']),
      examType: _emptyToNull(json['exam_type']),
      courseCategory: _emptyToNull(json['course_category']),
      assessmentMethod: _emptyToNull(json['assessment_method']),
      isDegree: json['is_degree'] == true ||
          json['is_degree'] == 1 ||
          json['is_degree'] == '1' ||
          json['is_degree'] == '是',
    );
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static double? _tryParseDoubleNullable(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value.toString());
    return parsed;
  }

  static String? _emptyToNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Whether this course has been passed.
  ///
  /// - `true`: passed
  /// - `false`: failed
  /// - `null`: unknown (empty, 未录入, 缓考, 缺考, 旷考, 作弊, --, unrecognized)
  bool? get isPassed {
    final t = displayGrade.trim();

    // Text-based: explicit pass
    if (RegExp(r'^(优秀|良好|中等|合格|及格)$').hasMatch(t)) return true;

    // Text-based: explicit fail
    if (RegExp(r'^(不及格|不合格|未通过|缺考|旷考|作弊)$').hasMatch(t)) return false;

    // Text-based: explicitly unknown / pending
    if (RegExp(r'^(未录入|缓考|--|)$').hasMatch(t)) return null;

    // Numeric: try to parse
    final numeric = double.tryParse(t);
    if (numeric != null) {
      if (numeric >= 60) return true;
      if (numeric < 60) return false;
    }

    // Unrecognized text → unknown
    return null;
  }

  /// Weighted average GPA: sum(gpa × credits) ÷ sum(credits).
  ///
  /// Only courses with non-null [gpa] and [credits] > 0 participate.
  /// Returns `null` (not 0.0) when no valid courses → display "--".
  static double? computeWeightedGpa(List<EduGrade> grades) {
    double totalWeighted = 0;
    double totalCredits = 0;

    for (final g in grades) {
      if (g.gpa != null && g.credits > 0) {
        totalWeighted += g.gpa! * g.credits;
        totalCredits += g.credits;
      }
    }

    if (totalCredits <= 0) return null;
    return totalWeighted / totalCredits;
  }

  @override
  String toString() => 'EduGrade(name: $name, grade: $displayGrade, '
      'credits: $credits, gpa: $gpa, isDegree: $isDegree, '
      'examType: $examType)';
}

class GradeComponent {
  final String name;
  final String? weight;
  final String score;

  const GradeComponent({
    required this.name,
    required this.weight,
    required this.score,
  });

  factory GradeComponent.fromJson(Map<String, dynamic> json) {
    return GradeComponent(
      name: (json['name'] ?? '').toString(),
      weight: EduGrade._emptyToNull(json['weight']),
      score: (json['score'] ?? '').toString(),
    );
  }
}

class EduGradeDetail {
  final bool success;
  final String courseName;
  final String totalGrade;
  final List<GradeComponent> components;
  final String? message;

  const EduGradeDetail({
    required this.success,
    required this.courseName,
    required this.totalGrade,
    required this.components,
    required this.message,
  });

  factory EduGradeDetail.fromJson(Map<String, dynamic> json) {
    return EduGradeDetail(
      success: json['success'] == true,
      courseName: (json['course_name'] ?? '').toString(),
      totalGrade: (json['total_grade'] ?? '').toString(),
      components: (json['components'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => GradeComponent.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      message: EduGrade._emptyToNull(json['message']),
    );
  }
}
