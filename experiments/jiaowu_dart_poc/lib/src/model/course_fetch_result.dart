import 'raw_course.dart';

enum CourseSource { desktop, mobile }

/// 一次成功课表查询的结果，以及用于跨实现比较的 canonical JSON。
final class CourseFetchResult {
  CourseFetchResult(
      {required Iterable<RawCourse> courses, required this.source})
      : courses = List.unmodifiable(courses);

  final List<RawCourse> courses;
  final CourseSource source;

  bool get isEmpty => courses.isEmpty;

  List<Map<String, String>> get canonicalJson {
    final sorted = List<RawCourse>.of(courses)
      ..sort((left, right) {
        final byWeekday = _compare(left.weekDay, right.weekDay);
        if (byWeekday != 0) return byWeekday;
        final bySection = _compare(left.section, right.section);
        if (bySection != 0) return bySection;
        final byName = left.name.compareTo(right.name);
        if (byName != 0) return byName;
        final byWeeks = left.weekExpression.compareTo(right.weekExpression);
        if (byWeeks != 0) return byWeeks;
        return left.location.compareTo(right.location);
      });
    return sorted.map((course) => course.toCanonicalJson()).toList();
  }

  static int _compare(String left, String right) {
    final leftNumber = int.tryParse(RegExp(r'^\d+').stringMatch(left) ?? '');
    final rightNumber = int.tryParse(RegExp(r'^\d+').stringMatch(right) ?? '');
    if (leftNumber != null &&
        rightNumber != null &&
        leftNumber != rightNumber) {
      return leftNumber.compareTo(rightNumber);
    }
    return left.compareTo(right);
  }
}
