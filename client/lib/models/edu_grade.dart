/// Typed grade model — replaces raw Map<String, dynamic> in grade display code.
class EduGrade {
  final String name; // course name
  final String
      displayGrade; // original grade text: "64.7", "优秀", "良好", "--", etc.
  final double credits; // course credits, default 0
  final double? gpa; // nullable — pass/fail courses have no GPA
  final bool isDegree; // is this a degree course

  const EduGrade({
    required this.name,
    required this.displayGrade,
    required this.credits,
    required this.gpa,
    required this.isDegree,
  });

  factory EduGrade.fromJson(Map<String, dynamic> json) {
    return EduGrade(
      name: (json['name'] ?? '').toString(),
      displayGrade: (json['grade'] ?? '--').toString(),
      credits: _parseDouble(json['credits']),
      gpa: _tryParseDoubleNullable(json['gpa']),
      isDegree: json['is_degree'] == true || json['is_degree'] == 1,
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
      'credits: $credits, gpa: $gpa, isDegree: $isDegree)';
}
