import '../model/credit_requirement.dart';

/// 学校 AJAX 树的规则节点并入最近的真实模块，避免重复展示培养要求。
abstract final class CreditRequirementJsonParser {
  static CreditRequirement parse(Object? payload) {
    if (payload is! List) return _failure();
    final modules = <_Module>[];
    final improvements = <ImprovementCourse>[];
    void visit(Object? node, _Module? parent) {
      if (node is! Map) return;
      final name = _text(node['xfyqjdmc']);
      var nextParent = parent;
      if (name.isNotEmpty) {
        final module = _Module(node);
        if (name.contains('提高课程')) {
          improvements.addAll(module.courses.map((c) => ImprovementCourse(
                courseId: c.courseId,
                courseName: c.courseName,
                credits: c.credits,
                grade: c.grade,
                status: c.status,
              )));
        } else if (_rule.hasMatch(name.replaceAll(RegExp(r'\s+'), '')) &&
            parent != null) {
          parent.merge(module);
        } else {
          modules.add(module);
          nextParent = module;
        }
      }
      final children = node['xfyqjdList'];
      if (children is List) {
        for (final child in children) {
          visit(child, nextParent);
        }
      }
    }

    for (final node in payload) {
      visit(node, null);
    }
    if (payload.isNotEmpty && modules.isEmpty && improvements.isEmpty)
      return _failure();
    return CreditRequirement(
        success: true,
        status: payload.isEmpty ? 'empty' : 'available',
        modules: modules.map((m) => m.build()).toList(),
        improvementCourses: improvements);
  }

  static final _rule = RegExp(r'^至少修\d+(?:\.\d+)?(?:学分|门)(?:[（(][^）)]*[)）])?$');
  static CreditRequirement _failure() => const CreditRequirement(
      success: false,
      status: 'parse_failed',
      modules: [],
      improvementCourses: [],
      errorCode: 'CREDIT_REQUIREMENT_PARSE_FAILED',
      message: '学分要求数据结构发生变化');
}

String _text(Object? value) => value?.toString().trim() ?? '';
double? _number(Object? value) => double.tryParse(_text(value));
bool _completed(ModuleCourse c) => c.status == '通过' || c.status == '课程替代';

class _Module {
  _Module(Map raw)
      : name = _text(raw['xfyqjdmc']),
        requiredCredits = _number(raw['yqzdxf']),
        requiredCount = _number(raw['kczdms'])?.toInt() {
    final list = raw['kcList'];
    if (list is! List) return;
    for (final item in list.whereType<Map>()) {
      earned += _number(item['yxxf']) ?? 0;
      final courseName = _text(item['kcmc']);
      if (courseName.isEmpty) continue;
      final grade = _text(item['cj']);
      final numericGrade = _number(item['bfzcj']);
      final actualYear = _text(item['xnmc']);
      final actualSemester = _text(item['xqmc']);
      final status = grade == '未开放'
          ? '未开放'
          : _text(item['tdbj']) == '1'
              ? '课程替代'
              : (_number(item['yxxf']) ?? 0) > 0
                  ? '通过'
                  : numericGrade != null
                      ? (numericGrade >= 60 ? '通过' : '不及格')
                      : actualYear.isNotEmpty || actualSemester.isNotEmpty
                          ? '已选'
                          : '未选';
      courses.add(ModuleCourse(
          courseId: _text(item['kch']),
          courseName: courseName,
          credits: _number(item['xf']) ?? 0,
          grade: grade,
          status: status,
          suggestedYear: _text(item['jyxdxnmc']),
          suggestedSemester: _text(item['jyxdxqmc']),
          actualYear: actualYear,
          actualSemester: actualSemester));
    }
  }
  final String name;
  final double? requiredCredits;
  final int? requiredCount;
  double earned = 0;
  final courses = <ModuleCourse>[];

  void merge(_Module rule) {
    for (final course in rule.courses) {
      if (courses.any((c) =>
          c.courseId == course.courseId &&
          c.courseName == course.courseName &&
          c.actualYear == course.actualYear &&
          c.actualSemester == course.actualSemester)) continue;
      courses.add(course);
      if (_completed(course)) earned += course.credits;
    }
  }

  CreditModule build() {
    final count = courses.where(_completed).length;
    final status = requiredCredits == null && requiredCount == null
        ? 'unknown'
        : (requiredCredits == null || earned >= requiredCredits!) &&
                (requiredCount == null || count >= requiredCount!)
            ? 'completed'
            : earned > 0 || count > 0
                ? 'in_progress'
                : 'shortfall';
    return CreditModule(
        name: name,
        requiredCredits: requiredCredits,
        earnedCredits: earned,
        status: status,
        courses: courses,
        requiredCourseCount: requiredCount);
  }
}
