class CourseTerm {
  final String id;
  final String year;
  final int semester;
  final String title;
  final DateTime? startDate;
  final DateTime? endDate;
  final int maxWeek;
  final bool isCurrent;

  const CourseTerm({
    required this.id,
    required this.year,
    required this.semester,
    required this.title,
    this.startDate,
    this.endDate,
    this.maxWeek = 20,
    this.isCurrent = false,
  });

  CourseTerm copyWith({
    String? id,
    String? year,
    int? semester,
    String? title,
    DateTime? startDate,
    DateTime? endDate,
    int? maxWeek,
    bool? isCurrent,
  }) {
    return CourseTerm(
      id: id ?? this.id,
      year: year ?? this.year,
      semester: semester ?? this.semester,
      title: title ?? this.title,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      maxWeek: maxWeek ?? this.maxWeek,
      isCurrent: isCurrent ?? this.isCurrent,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'year': year,
        'semester': semester,
        'title': title,
        'start_date': startDate?.toIso8601String(),
        'end_date': endDate?.toIso8601String(),
        'max_week': maxWeek,
        'is_current': isCurrent,
      };

  factory CourseTerm.fromJson(Map<String, dynamic> json) {
    return CourseTerm(
      id: json['id'] as String,
      year: json['year'] as String,
      semester: json['semester'] as int,
      title: json['title'] as String,
      startDate: json['start_date'] != null
          ? DateTime.parse(json['start_date'] as String)
          : null,
      endDate: json['end_date'] != null
          ? DateTime.parse(json['end_date'] as String)
          : null,
      maxWeek: (json['max_week'] as num?)?.toInt() ?? 20,
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }

  /// 自动推断默认学期
  static CourseTerm inferCurrentTerm() {
    final now = DateTime.now();
    int currentYear = now.year;
    String year;
    int semester;
    String title;

    if (now.month >= 2 && now.month <= 7) {
      year = '${currentYear - 1}';
      semester = 12;
      title = '${currentYear - 1}-$currentYear 第二学期';
    } else if (now.month == 1) {
      year = '${currentYear - 1}';
      semester = 3;
      title = '${currentYear - 1}-$currentYear 第一学期';
    } else {
      year = '$currentYear';
      semester = 3;
      title = '$currentYear-${currentYear + 1} 第一学期';
    }

    return CourseTerm(
      id: '${year}_$semester',
      year: year,
      semester: semester,
      title: title,
      isCurrent: true,
    );
  }
}

class CourseTermCatalog {
  static String titleFor(String year, int semester) {
    final y = int.tryParse(year) ?? DateTime.now().year;
    return '$y-${y + 1} ${semester == 3 ? "第一学期" : "第二学期"}';
  }

  static List<CourseTerm> generate({
    required int enrollmentYear,
    int? untilYear,
  }) {
    final now = DateTime.now();
    final endYear = untilYear ?? now.year + 1;
    final terms = <CourseTerm>[];

    for (int y = enrollmentYear; y <= endYear; y++) {
      terms.add(CourseTerm(
        id: '${y}_3',
        year: '$y',
        semester: 3,
        title: titleFor('$y', 3),
      ));
      terms.add(CourseTerm(
        id: '${y}_12',
        year: '$y',
        semester: 12,
        title: titleFor('$y', 12),
      ));
    }

    terms.sort((a, b) {
      final yearCompare = b.year.compareTo(a.year);
      if (yearCompare != 0) return yearCompare;
      return b.semester.compareTo(a.semester);
    });

    return terms;
  }
}
