import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import '../model/academic_situation.dart';

/// 学业情况解析器。
///
/// 严格迁移 Python 端的 parse_academic_situation_html 逻辑。
abstract final class AcademicSituationParser {
  /// 解析学业情况 HTML。
  static AcademicSituation parse(String html) {
    final document = html_parser.parse(html);
    final plainText = _normalizeText(document.body?.text ?? '');

    if (_looksLikeLoginPage(html) || plainText.isEmpty) {
      return _structureFailure();
    }

    final allGpa = _extractGpaValueAny(plainText, _allGpaLabels);
    final degreeGpa = _extractGpaValueAny(plainText, _degreeGpaLabels);
    final parts = _splitAcademicSummary(plainText);
    final totalPart = parts[0];
    final degreePart = parts[1];

    final totalCourses = _findIntOptional(totalPart, r'计划总课程(?:为)?\s*(\d+)\s*门');
    final passedCourses = _findIntOptional(totalPart, r'(?<!未)通过\s*(\d+)\s*门');
    final failedCourses = _findIntOptional(totalPart, r'未通过\s*(\d+)\s*门');
    final notStartedCourses = _findIntOptional(totalPart, r'未修\s*(\d+)\s*门');
    final inProgressCourses = _findIntOptional(totalPart, r'在读\s*(\d+)\s*门');

    final degreeTotalCourses = _findIntOptional(degreePart, r'计划学位课程(?:为)?\s*(\d+)\s*门');
    final degreePassedCourses = _findIntOptional(degreePart, r'(?<!未)通过\s*(\d+)\s*门');
    final degreeFailedCourses = _findIntOptional(degreePart, r'未通过\s*(\d+)\s*门');
    final degreeNotStartedCourses = _findIntOptional(degreePart, r'未修\s*(\d+)\s*门');
    final degreeInProgressCourses = _findIntOptional(degreePart, r'在读\s*(\d+)\s*门');

    // 验证结构
    final compactText = _compactText(plainText);
    final hasAllGpaAnchor = _allGpaLabels.any((label) => compactText.contains(_compactText(label)));
    final hasDegreeGpaAnchor = _degreeGpaLabels.any((label) => compactText.contains(_compactText(label)));
    final hasCountAnchor = compactText.contains('计划总课程') &&
        ['通过', '未通过', '未修', '在读'].any((label) => compactText.contains(label));

    final hasParsedGpa = allGpa != null || degreeGpa != null;
    final hasCompleteCounts = totalCourses != null &&
        passedCourses != null &&
        failedCourses != null &&
        notStartedCourses != null &&
        inProgressCourses != null &&
        degreeTotalCourses != null &&
        degreePassedCourses != null &&
        degreeFailedCourses != null &&
        degreeNotStartedCourses != null &&
        degreeInProgressCourses != null;

    if (!(hasAllGpaAnchor && hasDegreeGpaAnchor && hasCountAnchor && hasParsedGpa && hasCompleteCounts)) {
      return _structureFailure();
    }

    final coursesResult = _parseAcademicCourses(document);

    return AcademicSituation(
      success: true,
      allGpa: allGpa,
      degreeGpa: degreeGpa,
      totalCourses: totalCourses,
      passedCourses: passedCourses,
      failedCourses: failedCourses,
      notStartedCourses: notStartedCourses,
      inProgressCourses: inProgressCourses,
      degreeTotalCourses: degreeTotalCourses,
      degreePassedCourses: degreePassedCourses,
      degreeFailedCourses: degreeFailedCourses,
      degreeNotStartedCourses: degreeNotStartedCourses,
      degreeInProgressCourses: degreeInProgressCourses,
      courses: coursesResult.courses,
      coursesStatus: coursesResult.status,
    );
  }

  static const _allGpaLabels = [
    '当前所有课程平均学分绩点',
    '所有课程平均学分绩点',
    '当前所有课程GPA',
  ];

  static const _degreeGpaLabels = [
    '当前学位课程平均学分绩点',
    '当前学位课平均学分绩点',
    '学位课程平均学分绩点',
    '学位课平均学分绩点',
    '当前学位课程GPA',
    '当前学位课GPA',
    '学位课GPA',
  ];

  static AcademicSituation _structureFailure() {
    return const AcademicSituation(
      success: false,
      allGpa: null,
      degreeGpa: null,
      totalCourses: null,
      passedCourses: null,
      failedCourses: null,
      notStartedCourses: null,
      inProgressCourses: null,
      degreeTotalCourses: null,
      degreePassedCourses: null,
      degreeFailedCourses: null,
      degreeNotStartedCourses: null,
      degreeInProgressCourses: null,
      courses: [],
      coursesStatus: 'parse_failed',
      errorCode: 'ACADEMIC_SITUATION_STRUCTURE_CHANGED',
      message: '学业情况页面结构发生变化',
    );
  }

  static bool _looksLikeLoginPage(String html) {
    return html.contains('login_slogin.html') ||
           html.contains('统一身份认证');
  }

  static double? _extractGpaValueAny(String text, List<String> labels) {
    final compact = _compactText(text);

    for (final label in labels) {
      final compactLabel = _compactText(label);
      final index = compact.indexOf(compactLabel);
      if (index < 0) continue;

      final window = compact.substring(index, (index + 100).clamp(0, compact.length));
      final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)').firstMatch(window);
      if (match != null) {
        return double.tryParse(match.group(1)!);
      }
    }
    return null;
  }

  static List<String> _splitAcademicSummary(String text) {
    final degreeMarker = '计划学位课程';
    final index = text.indexOf(degreeMarker);

    if (index < 0) {
      return [text, ''];
    }

    return [
      text.substring(0, index),
      text.substring(index),
    ];
  }

  static int? _findIntOptional(String text, String pattern) {
    final match = RegExp(pattern).firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static ({List<AcademicCourse> courses, String status}) _parseAcademicCourses(
    dom.Document document,
  ) {
    for (final table in document.querySelectorAll('table')) {
      final headerIndex = _academicCourseHeaderIndex(table);
      if (headerIndex < 0) continue;

      final parsed = _parseAcademicCourseTable(table, headerIndex);
      if (parsed != null) {
        return (courses: parsed, status: 'available');
      }

      final rows = table.querySelectorAll('tr');
      final dataRows = rows.skip(headerIndex + 1);
      final hasData = dataRows.any((row) => _normalizeText(row.text).isNotEmpty);

      return (courses: [], status: hasData ? 'parse_failed' : 'empty');
    }

    if (_hasDynamicCourseSource(document)) {
      return (courses: [], status: 'dynamic_source_unresolved');
    }

    return (courses: [], status: 'not_present');
  }

  static int _academicCourseHeaderIndex(dom.Element table) {
    final rows = table.querySelectorAll('tr');
    for (var i = 0; i < rows.length; i++) {
      final cells = rows[i]
          .querySelectorAll('th, td')
          .map((cell) => _normalizeText(cell.text))
          .toList();

      if (cells.contains('课程名称') &&
          cells.contains('最大成绩') &&
          cells.contains('修读状态')) {
        return i;
      }
    }
    return -1;
  }

  static List<AcademicCourse>? _parseAcademicCourseTable(
    dom.Element table,
    int headerIndex,
  ) {
    final rows = table.querySelectorAll('tr');
    if (rows.length <= headerIndex) return null;

    final headers = rows[headerIndex]
        .querySelectorAll('th, td')
        .map((cell) => _normalizeText(cell.text))
        .toList();

    const fieldMap = {
      '修读状态': 'study_status',
      '成绩学年': 'academic_year',
      '学期': 'semester',
      '课程号': 'course_code',
      '课程名称': 'course_name',
      '学时': 'hours',
      '课程性质': 'course_nature',
      '学分': 'credits',
      '课程类别': 'course_category',
      '最大成绩': 'max_grade',
      '绩点': 'gpa',
      '成绩': 'grade',
      '补考': 'makeup_grade',
      '重修': 'retake_grade',
    };

    final courses = <AcademicCourse>[];

    for (final tr in rows.skip(headerIndex + 1)) {
      final cells = tr
          .querySelectorAll('td')
          .map((td) => _normalizeText(td.text))
          .toList();

      if (cells.every((c) => c.isEmpty)) continue;

      final row = <String, String?>{};
      for (var i = 0; i < headers.length && i < cells.length; i++) {
        final field = fieldMap[headers[i]];
        if (field != null) {
          row[field] = _emptyToNoneText(cells[i]);
        }
      }

      final courseName = row['course_name'];
      if (courseName == null || courseName.isEmpty) continue;

      final courseId = row['course_code'] ?? '';
      final credits = _toFloat(row['credits']);
      final isDegree = _isDegreeCourse(row);
      final hasRetake = _hasValue(row['retake_grade']);
      final effectiveGrade = _effectiveGrade(row) ?? '';
      final effectivePassed = _effectivePassed(row);

      courses.add(AcademicCourse(
        courseName: courseName,
        courseId: courseId,
        credits: credits,
        status: row['study_status'] ?? '',
        effectiveGrade: effectiveGrade,
        effectivePassed: effectivePassed,
        isDegree: isDegree,
        hasRetake: hasRetake,
        maxGrade: row['max_grade'],
        gpa: _toNullableFloat(row['gpa']),
        courseCategory: row['course_category'],
        courseNature: row['course_nature'],
      ));
    }

    return courses.isEmpty ? null : courses;
  }

  static bool _hasDynamicCourseSource(dom.Document document) {
    if (document.querySelectorAll('iframe, [data-url], [data-ajax], [data-source]').isNotEmpty) {
      return true;
    }

    final scriptText = document
        .querySelectorAll('script')
        .map((s) => s.text)
        .join(' ');

    return ['\$.ajax', 'fetch(', '.DataTable(', '.load(']
        .any((marker) => scriptText.contains(marker));
  }

  static String? _emptyToNoneText(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty || text == '--' || text == '—' || text == '-') {
      return null;
    }
    return text;
  }

  static bool _hasValue(String? value) => _emptyToNoneText(value) != null;

  static double _toFloat(String? value) {
    if (value == null) return 0.0;
    return double.tryParse(value) ?? 0.0;
  }

  static double? _toNullableFloat(String? value) {
    if (value == null) return null;
    return double.tryParse(value);
  }

  static bool _isDegreeCourse(Map<String, String?> row) {
    final text = '${row['course_nature'] ?? ''} ${row['course_category'] ?? ''}';
    return text.contains('学位');
  }

  static String? _effectiveGrade(Map<String, String?> row) {
    for (final key in ['max_grade', 'retake_grade', 'makeup_grade', 'grade']) {
      final value = _emptyToNoneText(row[key]);
      if (value != null) return value;
    }
    return null;
  }

  static bool _effectivePassed(Map<String, String?> row) {
    final grade = _effectiveGrade(row);
    if (grade == null) return false;

    final numeric = double.tryParse(grade);
    if (numeric != null) {
      return numeric >= 60;
    }

    return ['通过', '合格', '良好', '优秀', '及格'].any((p) => grade.contains(p));
  }

  static String _normalizeText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _compactText(String value) {
    return value.replaceAll(RegExp(r'\s+'), '');
  }
}
