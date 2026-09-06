import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import '../model/credit_requirement.dart';

/// 学分要求解析器。
///
/// 严格迁移 Python 端的 parse_credit_requirement_html 逻辑。
abstract final class CreditRequirementParser {
  /// 解析学分要求 HTML。
  static CreditRequirement parse(String html) {
    final document = html_parser.parse(html);
    final plainText = _normalizeText(document.body?.text ?? '');

    if (_looksLikeLoginPage(html) || plainText.isEmpty) {
      return _failure('empty');
    }

    // 解析模块和提高课程
    final result = _parseModulesAndImprovementCourses(document, plainText);
    final modules = result.modules;
    final improvementCourses = result.improvementCourses;

    if (modules.isEmpty && improvementCourses.isEmpty) {
      // 检测动态加载
      if (_hasDynamicCourseSource(document)) {
        return _failure('dynamic_source_unresolved');
      }

      // 检测是否有模块标题但解析失败
      if (_hasCreditReqHeaders(plainText)) {
        return _failure('parse_failed');
      }

      return _failure('empty');
    }

    return CreditRequirement(
      success: true,
      status: 'available',
      modules: modules,
      improvementCourses: improvementCourses,
    );
  }

  static CreditRequirement _failure(String status) {
    return CreditRequirement(
      success: false,
      status: status,
      modules: const [],
      improvementCourses: const [],
      errorCode: 'CREDIT_REQUIREMENT_PARSE_FAILED',
      message: '学分要求解析失败',
    );
  }

  static bool _looksLikeLoginPage(String html) {
    return html.contains('login_slogin.html') || html.contains('统一身份认证');
  }

  static bool _hasCreditReqHeaders(String text) {
    return RegExp(r'学籍预警|学分要求|模块|要求最低|提高课程|最低学分').hasMatch(text);
  }

  static bool _hasDynamicCourseSource(dom.Document document) {
    if (document
        .querySelectorAll('iframe, [data-url], [data-ajax], [data-source]')
        .isNotEmpty) {
      return true;
    }

    final scriptText =
        document.querySelectorAll('script').map((s) => s.text).join(' ');

    return [r'$.ajax', 'fetch(', '.DataTable(', '.load(']
        .any((marker) => scriptText.contains(marker));
  }

  static ({List<CreditModule> modules, List<ImprovementCourse> improvementCourses})
      _parseModulesAndImprovementCourses(
    dom.Document document,
    String plainText,
  ) {
    // Strategy 1: 基于文本分段解析
    final textResult = _parseFromText(plainText);
    var modules = textResult.modules;
    var improvementCourses = textResult.improvementCourses;

    if (modules.isEmpty && improvementCourses.isEmpty) {
      // Strategy 2: 基于表格解析（回退）
      return _parseFromTables(document);
    }

    // 尝试从表格提取课程数据并分配给模块
    final allTableCourses = _extractAllCoursesFromTables(document);
    if (allTableCourses.isNotEmpty) {
      // 清空文本解析的课程，使用表格解析的课程（更可靠）
      modules = modules.map((m) =>
        CreditModule(
          name: m.name,
          requiredCredits: m.requiredCredits,
          earnedCredits: m.earnedCredits,
          status: m.status,
          courses: const [], // 清空
          requiredCourseCount: m.requiredCourseCount,
        )
      ).toList();

      improvementCourses = [];

      _assignCoursesToModules(modules, allTableCourses, plainText);
      improvementCourses = _extractImprovementCourses(allTableCourses, plainText);
    }

    return (modules: modules, improvementCourses: improvementCourses);
  }

  static ({List<CreditModule> modules, List<ImprovementCourse> improvementCourses})
      _parseFromText(String plainText) {
    final modules = <CreditModule>[];
    final improvementCourses = <ImprovementCourse>[];

    // 查找所有模块标题位置
    final modulePatterns = [
      r'(通识教育理论必修)',
      r'(美育模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(自然模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(体育模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(人文模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(思政模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(外语模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(计算机模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(其他模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(学科基础[^\s，,。.]*(?:模块)?(?:[（(][^)）]+[)）])?)',
      r'(专业模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(实践模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(创新模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'(三选一模块[^\s，,。.]*(?:[（(][^)）]+[)）])?)',
      r'([A-Za-z一-鿿][^\s，,。.]{0,12}模块[^\s，,。.]*?(?:[（(][^)）]+[)）])?)',
      r'(提高课程)',
    ];

    final segments = <({int pos, String name})>[];

    for (final pattern in modulePatterns) {
      for (final match in RegExp(pattern).allMatches(plainText)) {
        final name = match.group(0)!.trim();
        if (name.length >= 2 && name.length <= 40) {
          segments.add((pos: match.start, name: name));
        }
      }
    }

    // 去重：相同位置保留最长的名称
    segments.sort((a, b) {
      final posComp = a.pos.compareTo(b.pos);
      if (posComp != 0) return posComp;
      return b.name.length.compareTo(a.name.length);
    });

    final deduped = <({int pos, String name})>[];
    final seenPositions = <int>{};

    for (final seg in segments) {
      if (!seenPositions.contains(seg.pos) &&
          !seenPositions.any((p) => (seg.pos - p).abs() < 5)) {
        deduped.add(seg);
        seenPositions.add(seg.pos);
      }
    }

    // 为每个模块解析其文本段
    for (var i = 0; i < deduped.length; i++) {
      final start = deduped[i].pos;
      final end = i + 1 < deduped.length ? deduped[i + 1].pos : plainText.length;
      final segmentText = plainText.substring(start, end);
      final name = deduped[i].name;

      final isImprovement = name.contains('提高课程');

      if (isImprovement) {
        // 提高课程暂时不从文本段解析，等待表格数据
        continue;
      }

      final requiredCredits = _extractRequiredCredits(segmentText);
      final requiredCourseCount = _extractRequiredCourseCount(segmentText);
      final earnedCredits = _extractEarnedCredits(segmentText);

      final status = _computeModuleStatus(
        requiredCredits: requiredCredits,
        earnedCredits: earnedCredits,
        requiredCourseCount: requiredCourseCount,
        completedCourseCount: 0,
      );

      modules.add(CreditModule(
        name: name,
        requiredCredits: requiredCredits,
        earnedCredits: earnedCredits,
        status: status,
        courses: const [],
        requiredCourseCount: requiredCourseCount,
      ));
    }

    return (modules: modules, improvementCourses: improvementCourses);
  }

  static ({List<CreditModule> modules, List<ImprovementCourse> improvementCourses})
      _parseFromTables(dom.Document document) {
    // 表格解析回退策略（简化版）
    return (modules: const [], improvementCourses: const []);
  }

  static List<_RawCourse> _extractAllCoursesFromTables(dom.Document document) {
    final allCourses = <_RawCourse>[];

    for (final table in document.querySelectorAll('table')) {
      final headers = _detectCourseTableHeaders(table);
      if (headers.isEmpty || !headers.containsValue('course_name')) {
        continue;
      }

      final courses = _parseCourseRows(table, headers);
      allCourses.addAll(courses);
    }

    return allCourses;
  }

  static Map<int, String> _detectCourseTableHeaders(dom.Element table) {
    const fieldMap = {
      '课程号': 'course_code',
      '课程名称': 'course_name',
      '课程学分': 'credits',
      '学分': 'credits',
      '建议修读学年': 'suggested_year',
      '建议修读学期': 'suggested_semester',
      '实际修读学年': 'actual_year',
      '实际修读学期': 'actual_semester',
      '选必修': 'course_nature',
      '课程性质': 'course_nature',
      '成绩': 'grade',
      '修读状态': 'raw_status',
      '状态': 'raw_status',
      '备注': 'remark',
    };

    final rows = table.querySelectorAll('tr');
    for (final tr in rows) {
      final cells =
          tr.querySelectorAll('th, td').map((e) => _normalizeText(e.text)).toList();

      if (cells.contains('课程名称') || cells.contains('课程号')) {
        final headerMap = <int, String>{};
        for (var i = 0; i < cells.length; i++) {
          final field = fieldMap[cells[i]];
          if (field != null) {
            headerMap[i] = field;
          }
        }
        return headerMap;
      }
    }

    return {};
  }

  static List<_RawCourse> _parseCourseRows(
    dom.Element table,
    Map<int, String> headers,
  ) {
    final courses = <_RawCourse>[];
    final rows = table.querySelectorAll('tr');
    var foundHeader = false;

    for (final tr in rows) {
      final cells = tr.querySelectorAll('td');

      if (cells.isEmpty) continue;

      // 跳过表头行
      if (!foundHeader) {
        final firstCell = _normalizeText(cells.first.text);
        if (firstCell == '课程号' || firstCell == '课程名称') {
          foundHeader = true;
        }
        continue;
      }

      final row = <String, String?>{};
      for (var i = 0; i < cells.length; i++) {
        final field = headers[i];
        if (field != null) {
          row[field] = _emptyToNoneText(_normalizeText(cells[i].text));
        }
      }

      final courseName = row['course_name'];
      if (courseName == null || courseName.isEmpty) continue;

      courses.add(_RawCourse(
        courseCode: row['course_code'] ?? '',
        courseName: courseName,
        credits: _toFloat(row['credits']),
        grade: row['grade'] ?? '',
        rawStatus: row['raw_status'] ?? '',
        suggestedYear: row['suggested_year'],
        suggestedSemester: row['suggested_semester'],
        actualYear: row['actual_year'],
        actualSemester: row['actual_semester'],
        courseNature: row['course_nature'],
        remark: row['remark'],
      ));
    }

    return courses;
  }

  static void _assignCoursesToModules(
    List<CreditModule> modules,
    List<_RawCourse> allCourses,
    String plainText,
  ) {
    // 查找模块在文本中的位置
    final modulePositions = <({int pos, CreditModule module})>[];

    for (final module in modules) {
      final pos = plainText.indexOf(module.name);
      if (pos >= 0) {
        modulePositions.add((pos: pos, module: module));
      }
    }

    modulePositions.sort((a, b) => a.pos.compareTo(b.pos));

    if (modulePositions.isEmpty) return;

    // 为每个课程分配到最近的前置模块
    for (final rawCourse in allCourses) {
      final coursePos = plainText.indexOf(rawCourse.courseName);
      if (coursePos < 0) continue;

      // 跳过提高课程
      if (_isImprovementCourse(rawCourse.courseName, plainText, coursePos)) {
        continue;
      }

      // 查找最后一个在课程前出现的模块
      CreditModule? assigned;
      for (final item in modulePositions) {
        if (item.pos <= coursePos) {
          assigned = item.module;
        } else {
          break;
        }
      }

      if (assigned != null) {
        // 需要创建新的模块实例（因为 final 字段）
        final idx = modules.indexOf(assigned);
        if (idx >= 0) {
          final existingCourses = List<ModuleCourse>.from(assigned.courses);
          existingCourses.add(_rawCourseToModuleCourse(rawCourse));

          final newEarnedCredits = existingCourses.fold<double>(
            0.0,
            (sum, c) => sum + c.credits,
          );

          final newStatus = _computeModuleStatus(
            requiredCredits: assigned.requiredCredits,
            earnedCredits: newEarnedCredits,
            requiredCourseCount: assigned.requiredCourseCount,
            completedCourseCount: existingCourses.length,
          );

          modules[idx] = CreditModule(
            name: assigned.name,
            requiredCredits: assigned.requiredCredits,
            earnedCredits: newEarnedCredits,
            status: newStatus,
            courses: existingCourses,
            requiredCourseCount: assigned.requiredCourseCount,
          );
        }
      }
    }
  }

  static List<ImprovementCourse> _extractImprovementCourses(
    List<_RawCourse> allCourses,
    String plainText,
  ) {
    final improvementPos = plainText.indexOf('提高课程');
    if (improvementPos < 0) return [];

    final improvementCourses = <ImprovementCourse>[];

    for (final rawCourse in allCourses) {
      final coursePos = plainText.indexOf(rawCourse.courseName);
      if (coursePos > improvementPos) {
        improvementCourses.add(ImprovementCourse(
          courseId: rawCourse.courseCode,
          courseName: rawCourse.courseName,
          credits: rawCourse.credits,
          grade: rawCourse.grade,
          status: rawCourse.rawStatus,
        ));
      }
    }

    return improvementCourses;
  }

  static bool _isImprovementCourse(String courseName, String plainText, int coursePos) {
    final improvementPos = plainText.indexOf('提高课程');
    if (improvementPos < 0) return false;
    return coursePos > improvementPos;
  }

  static ModuleCourse _rawCourseToModuleCourse(_RawCourse raw) {
    return ModuleCourse(
      courseId: raw.courseCode,
      courseName: raw.courseName,
      credits: raw.credits,
      grade: raw.grade,
      status: raw.rawStatus,
      suggestedYear: raw.suggestedYear,
      suggestedSemester: raw.suggestedSemester,
      actualYear: raw.actualYear,
      actualSemester: raw.actualSemester,
    );
  }

  static double? _extractRequiredCredits(String text) {
    var match = RegExp(r'要求最低\s*(\d+(?:\.\d+)?)\s*学分').firstMatch(text);
    if (match != null) return double.tryParse(match.group(1)!);

    match = RegExp(r'最低\s*(\d+(?:\.\d+)?)\s*学分').firstMatch(text);
    if (match != null) return double.tryParse(match.group(1)!);

    match = RegExp(r'要求\s*(\d+(?:\.\d+)?)\s*学分').firstMatch(text);
    if (match != null) return double.tryParse(match.group(1)!);

    return null;
  }

  static int? _extractRequiredCourseCount(String text) {
    var match = RegExp(r'要求最低\s*(\d+)\s*门').firstMatch(text);
    if (match != null) return int.tryParse(match.group(1)!);

    match = RegExp(r'最低\s*(\d+)\s*门').firstMatch(text);
    if (match != null) return int.tryParse(match.group(1)!);

    return null;
  }

  static double _extractEarnedCredits(String text) {
    var match = RegExp(r'已获得\s*(\d+(?:\.\d+)?)\s*学分').firstMatch(text);
    if (match != null) return double.tryParse(match.group(1)!) ?? 0.0;

    match = RegExp(r'获得\s*(\d+(?:\.\d+)?)\s*学分').firstMatch(text);
    if (match != null) return double.tryParse(match.group(1)!) ?? 0.0;

    return 0.0;
  }

  static String _computeModuleStatus({
    required double? requiredCredits,
    required double earnedCredits,
    required int? requiredCourseCount,
    required int completedCourseCount,
  }) {
    if (requiredCredits == null && requiredCourseCount == null) {
      return 'unknown';
    }

    final creditSatisfied = requiredCredits == null || earnedCredits >= requiredCredits;
    final countSatisfied =
        requiredCourseCount == null || completedCourseCount >= requiredCourseCount;

    if (creditSatisfied && countSatisfied) {
      return 'completed';
    } else if (earnedCredits > 0 || completedCourseCount > 0) {
      return 'in_progress';
    } else {
      return 'shortfall';
    }
  }

  static String _normalizeText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String? _emptyToNoneText(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty || text == '--' || text == '—' || text == '-') {
      return null;
    }
    return text;
  }

  static double _toFloat(String? value) {
    if (value == null) return 0.0;
    return double.tryParse(value) ?? 0.0;
  }
}

/// 从表格解析的原始课程数据。
class _RawCourse {
  const _RawCourse({
    required this.courseCode,
    required this.courseName,
    required this.credits,
    required this.grade,
    required this.rawStatus,
    this.suggestedYear,
    this.suggestedSemester,
    this.actualYear,
    this.actualSemester,
    this.courseNature,
    this.remark,
  });

  final String courseCode;
  final String courseName;
  final double credits;
  final String grade;
  final String rawStatus;
  final String? suggestedYear;
  final String? suggestedSemester;
  final String? actualYear;
  final String? actualSemester;
  final String? courseNature;
  final String? remark;
}
