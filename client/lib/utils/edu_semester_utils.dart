/// Shared semester constants and helpers.
/// Zero dependency — safe to import from models, providers, widgets, and screens.
class EduSemester {
  EduSemester._();

  /// Backend values
  static const int first = 3;
  static const int second = 12;

  /// Human-readable label
  static String displayLabel(int semester) {
    return switch (semester) {
      first => '第一学期',
      second => '第二学期',
      _ => '未知学期',
    };
  }

  /// Only 3 or 12 are valid
  static bool isValid(int semester) {
    return semester == first || semester == second;
  }

  /// Semester label used in the selector chip: "2025-2026 第二学期"
  static String fullLabel(String year, int semester) {
    final y = int.tryParse(year) ?? DateTime.now().year;
    return '$y-${y + 1} ${displayLabel(semester)}';
  }

  /// Returns (year, semester) for the current academic term.
  ///
  /// - Feb–Jul: previous calendar year, second semester (12) — spring term
  /// - Aug–Dec: current calendar year, first semester (3) — fall term
  /// - Jan: previous calendar year, first semester (3) — fall term
  static ({String year, int semester}) current() {
    final now = DateTime.now();
    final m = now.month;
    final y = now.year;

    if (m >= 2 && m <= 7) {
      // Spring semester: academic year started previous calendar year
      return (year: (y - 1).toString(), semester: second);
    } else if (m == 1) {
      // January still belongs to the previous fall semester
      return (year: (y - 1).toString(), semester: first);
    } else {
      // Aug–Dec: current fall semester
      return (year: y.toString(), semester: first);
    }
  }

  /// Build a semester list from [enrollmentYear] up to the current actual
  /// semester, most recent first. Never generates future semesters.
  static List<({String year, int semester, bool isCurrent})> buildSemesterList(
    int enrollmentYear,
  ) {
    final cur = current();
    final curYear = int.tryParse(cur.year) ?? DateTime.now().year;
    final curSemester = cur.semester;

    final items = <({String year, int semester, bool isCurrent})>[];

    for (int y = curYear; y >= enrollmentYear; y--) {
      // For the current academic year, only include semesters up to the current one
      final maxSem = (y == curYear) ? curSemester : second;
      final minSem = (y == enrollmentYear)
          ? first // all semesters for enrollment year
          : first;

      // Go in reverse: second → first for display (most recent first)
      final semesters = maxSem >= second ? [second, first] : [first];
      for (final s in semesters) {
        if (s < minSem || s > maxSem) continue;
        items.add((
          year: y.toString(),
          semester: s,
          isCurrent: y.toString() == cur.year && s == cur.semester,
        ));
      }
    }

    return items;
  }
}
