import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'schema_mismatch.dart';

/// 学校个人学业数据的本地 fail-closed 解析器。
///
/// 解析器只返回经校验的结构化副本。输入可以是已经解码的 JSON、JSON 字符
/// 串或 HTML；HTML 中的 script、style 和事件属性永远不会被执行。
abstract final class AcademicParser {
  static const int maxInputBytes = 2 * 1024 * 1024;

  static List<Map<String, dynamic>> parseGrades(
    Object body, {
    String? year,
    int? semester,
  }) {
    final decoded = _decode(body, 'grades');
    if (decoded is Document) {
      return _parseHtmlCollection(
        decoded,
        dataset: 'grades',
        aliases: _gradeAliases,
        requiredFields: const {'name', 'grade'},
        allowEmpty: true,
      );
    }
    final rows = _jsonCollection(decoded, 'grades', const [
      'grades',
      'grade_list',
      'records',
      'items',
    ]);
    final result = _validateRows(
      rows,
      dataset: 'grades',
      requiredFields: const {'name'},
      keyFields: const [
        'student_grade_id',
        'course_id',
        'course_code',
        'name',
      ],
      allowEmpty: true,
    );
    if (year != null || semester != null) {
      // 查询参数不是事实来源；若响应回显了学期，必须与请求一致。
      for (final row in result) {
        _checkEcho(row, 'year', year, 'grades');
        _checkEcho(row, 'semester', semester, 'grades');
      }
    }
    return result;
  }

  /// 课表与 courses 使用同一解析规则；保留两个名称方便迁移旧调用方。
  static List<Map<String, dynamic>> parseSchedule(
    Object body, {
    String? year,
    int? semester,
  }) {
    final decoded = _decode(body, 'schedule');
    if (decoded is Document) {
      return _parseHtmlCollection(
        decoded,
        dataset: 'schedule',
        aliases: _scheduleAliases,
        requiredFields: const {'name'},
        allowEmpty: true,
      );
    }
    final rows = _jsonCollection(decoded, 'schedule', const [
      'courses',
      'kbList',
      'schedule',
      'items',
      'records',
    ]);
    final result = _validateRows(
      rows,
      dataset: 'schedule',
      requiredFields: const {'name'},
      keyFields: const ['course_id', 'course_code', 'name', 'weekday', 'time'],
      allowEmpty: true,
    );
    for (final row in result) {
      _checkEcho(row, 'year', year, 'schedule');
      _checkEcho(row, 'semester', semester, 'schedule');
    }
    return result;
  }

  static List<Map<String, dynamic>> parseCourses(
    Object body, {
    String? year,
    int? semester,
  }) =>
      parseSchedule(body, year: year, semester: semester);

  static List<Map<String, dynamic>> parseExams(Object body) {
    final decoded = _decode(body, 'exams');
    if (decoded is Document) {
      return _parseHtmlCollection(
        decoded,
        dataset: 'exams',
        aliases: _examAliases,
        requiredFields: const {'name'},
        allowEmpty: true,
      );
    }
    final rows = _jsonCollection(decoded, 'exams', const [
      'exams',
      'exam_list',
      'examSchedule',
      'items',
      'records',
    ]);
    return _validateRows(
      rows,
      dataset: 'exams',
      requiredFields: const {'name'},
      keyFields: const [
        'exam_id',
        'course_id',
        'course_code',
        'name',
        'start_time',
        'date',
      ],
      allowEmpty: true,
    );
  }

  static Map<String, dynamic> parseAcademicSituation(Object body) {
    final decoded = _decode(body, 'academic_situation');
    if (decoded is Document) {
      return _parseAcademicSituationHtml(decoded);
    }
    final map = _jsonMap(decoded, 'academic_situation');
    _requireSuccess(map, 'academic_situation');
    final result = _copyMap(map);
    final courses = map['courses'];
    if (courses != null) {
      result['courses'] = _validateRows(
        courses,
        dataset: 'academic_situation',
        requiredFields: const {'course_name'},
        keyFields: const ['course_code', 'course_name'],
        allowEmpty: true,
      );
    }
    // success/source/parser_version 是服务端版本契约；本地 HTML 解析结果会
    // 使用同样的字段，便于后续写入 AcademicCacheStore。
    if (result['success'] != true) {
      throw const SchemaMismatch(
        '学业情况响应未明确成功',
        dataset: 'academic_situation',
      );
    }
    return result;
  }

  static Map<String, dynamic> parseCreditRequirements(Object body) {
    final decoded = _decode(body, 'credit_requirements');
    if (decoded is Document) {
      return _parseCreditRequirementsHtml(decoded);
    }
    final map = _jsonMap(decoded, 'credit_requirements');
    _requireSuccess(map, 'credit_requirements');
    final result = _copyMap(map);
    final modules = map['modules'];
    final improvements = map['improvement_courses'];
    if (modules != null) {
      result['modules'] = _validateRows(
        modules,
        dataset: 'credit_requirements',
        requiredFields: const {'name'},
        keyFields: const ['id', 'name'],
        allowEmpty: true,
      );
    }
    if (improvements != null) {
      result['improvement_courses'] = _validateRows(
        improvements,
        dataset: 'credit_requirements',
        requiredFields: const {'course_name'},
        keyFields: const ['course_code', 'course_name'],
        allowEmpty: true,
      );
    }
    if (result['success'] != true) {
      throw const SchemaMismatch(
        '学分要求响应未明确成功',
        dataset: 'credit_requirements',
      );
    }
    return result;
  }

  /// 通用别名，供同步层在尚未确定具体数据集时使用。
  static List<Map<String, dynamic>> parseGradeList(Object body) =>
      parseGrades(body);

  static List<Map<String, dynamic>> parseCourseList(Object body) =>
      parseSchedule(body);

  static List<Map<String, dynamic>> parseExamList(Object body) =>
      parseExams(body);

  static dynamic _decode(Object body, String dataset) {
    if (body is String) {
      final bytes = utf8.encode(body);
      if (bytes.length > maxInputBytes) {
        throw SchemaMismatch('响应超过本地解析上限', dataset: dataset);
      }
      final text = body.trim();
      if (text.isEmpty) {
        throw SchemaMismatch('响应为空', dataset: dataset);
      }
      if (_looksLikeLogin(text)) {
        throw SchemaMismatch('学校会话已过期或返回登录页', dataset: dataset);
      }
      if (text.startsWith('<')) {
        final document = html_parser.parse(text);
        _rejectLoginDocument(document, dataset);
        return document;
      }
      try {
        final decoded = jsonDecode(text);
        _rejectLoginValue(decoded, dataset);
        return decoded;
      } on SchemaMismatch {
        rethrow;
      } catch (_) {
        throw SchemaMismatch('JSON 响应无法解析', dataset: dataset);
      }
    }
    if (body is Map || body is List) {
      _rejectLoginValue(body, dataset);
      return body;
    }
    throw SchemaMismatch('响应类型不受支持', dataset: dataset);
  }

  static List<dynamic> _jsonCollection(
    dynamic decoded,
    String dataset,
    List<String> keys,
  ) {
    if (decoded is List) return List<dynamic>.from(decoded);
    if (decoded is! Map) {
      throw SchemaMismatch('响应顶层结构错误', dataset: dataset);
    }
    final map = Map<String, dynamic>.from(decoded);
    _requireSuccess(map, dataset, allowMissing: true);
    for (final key in keys) {
      final value = map[key];
      if (value is List) return List<dynamic>.from(value);
    }
    final data = map['data'];
    if (data is List) return List<dynamic>.from(data);
    if (data is Map) {
      for (final key in keys) {
        final value = data[key];
        if (value is List) return List<dynamic>.from(value);
      }
    }
    throw SchemaMismatch('响应缺少数据列表', dataset: dataset);
  }

  static Map<String, dynamic> _jsonMap(dynamic decoded, String dataset) {
    if (decoded is! Map) {
      throw SchemaMismatch('响应顶层结构错误', dataset: dataset);
    }
    final map = Map<String, dynamic>.from(decoded);
    _requireSuccess(map, dataset, allowMissing: true);
    final data = map['data'];
    if (data is Map && map.keys.length <= 3) {
      // 保留 envelope 的成功标记，避免包装响应在展开后被误判为
      // 缺少 success。只复制结构化字段，不保留原始响应对象引用。
      return <String, dynamic>{
        ...Map<String, dynamic>.from(data),
        if (map['success'] != null) 'success': map['success'],
        if (map['ok'] != null) 'ok': map['ok'],
      };
    }
    return map;
  }

  static List<Map<String, dynamic>> _validateRows(
    Object? raw, {
    required String dataset,
    required Set<String> requiredFields,
    required List<String> keyFields,
    required bool allowEmpty,
  }) {
    if (raw is! Iterable) {
      throw SchemaMismatch('数据列表类型错误', dataset: dataset);
    }
    final rows = <Map<String, dynamic>>[];
    final byKey = <String, Map<String, dynamic>>{};
    for (final value in raw) {
      if (value is! Map) {
        throw SchemaMismatch('数据行类型错误', dataset: dataset);
      }
      final row = _copyMap(value);
      for (final field in requiredFields) {
        final normalized = _string(row[field]);
        if (normalized.isEmpty) {
          throw SchemaMismatch('必要字段缺失', dataset: dataset, field: field);
        }
        row[field] = normalized;
      }
      final key = _rowKey(row, keyFields);
      final previous = byKey[key];
      if (previous != null) {
        if (_canonicalJson(previous) != _canonicalJson(row)) {
          throw SchemaMismatch('重复记录内容冲突', dataset: dataset);
        }
        continue;
      }
      byKey[key] = row;
      rows.add(row);
    }
    if (!allowEmpty && rows.isEmpty) {
      throw SchemaMismatch('数据列表为空', dataset: dataset);
    }
    return rows;
  }

  static List<Map<String, dynamic>> _parseHtmlCollection(
    Document document, {
    required String dataset,
    required Map<String, String> aliases,
    required Set<String> requiredFields,
    required bool allowEmpty,
  }) {
    final candidates =
        <({Element table, Element headerRow, Map<int, String> headers})>[];
    for (final table in document.querySelectorAll('table')) {
      final rows = table.querySelectorAll('tr');
      for (final row in rows) {
        final cells = row.querySelectorAll('th,td');
        final mapped = <int, String>{};
        for (var index = 0; index < cells.length; index++) {
          final alias = aliases[_header(cells[index].text)];
          if (alias != null) mapped[index] = alias;
        }
        if (requiredFields.every(mapped.values.toSet().contains)) {
          candidates.add((table: table, headerRow: row, headers: mapped));
          break;
        }
      }
    }
    if (candidates.isEmpty) {
      throw SchemaMismatch('HTML 表格结构无法识别', dataset: dataset);
    }
    final rawRows = <Map<String, dynamic>>[];
    for (final candidate in candidates) {
      final rows = candidate.table.querySelectorAll('tr');
      for (final row in rows) {
        // 表头行可能由 <th> 或 <td> 组成，因此直接比较元素实例，
        // 不依赖单元格类型或表格中的固定行号。
        if (identical(row, candidate.headerRow)) {
          continue;
        }
        final allCells = row.querySelectorAll('th,td');
        final cells = row.querySelectorAll('td');
        if (cells.isEmpty) continue;
        final mapped = <String, dynamic>{};
        for (var index = 0; index < allCells.length; index++) {
          final cell = allCells[index];
          if (cell.localName != 'td') continue;
          final field = candidate.headers[index];
          if (field != null) mapped[field] = cell.text.trim();
        }
        if (mapped.values.every((value) => _string(value).isEmpty)) continue;
        rawRows.add(mapped);
      }
    }
    return _validateRows(
      rawRows,
      dataset: dataset,
      requiredFields: requiredFields,
      keyFields: _defaultKeyFields(dataset),
      allowEmpty: allowEmpty,
    );
  }

  static Map<String, dynamic> _parseAcademicSituationHtml(Document document) {
    final text = _visibleText(document);
    final hasSituationSummary = _containsAny(text, const [
      '学业情况',
      '课程总数',
      '总课程',
      '已修课程',
      '绩点',
      'gpa',
      '学分',
    ]);
    List<Map<String, dynamic>> tables;
    try {
      tables = _parseHtmlCollection(
        document,
        dataset: 'academic_situation',
        aliases: _academicAliases,
        requiredFields: const {'course_name'},
        allowEmpty: true,
      );
    } on SchemaMismatch {
      // 部分学校只展示汇总数字而没有课程表；只有明确的学业摘要词出现
      // 时才接受空课程集合，任意结构变化仍然抛出 SchemaMismatch。
      if (!hasSituationSummary) rethrow;
      tables = const <Map<String, dynamic>>[];
    }
    if (tables.isEmpty && !hasSituationSummary) {
      throw const SchemaMismatch('HTML 学业情况缺少已知字段',
          dataset: 'academic_situation');
    }
    return <String, dynamic>{
      'success': true,
      'source_kind': 'local_school_html',
      'parser_version': 'local-academic-v1',
      'courses_status': tables.isEmpty ? 'not_present' : 'available',
      'courses': tables,
    };
  }

  static Map<String, dynamic> _parseCreditRequirementsHtml(Document document) {
    final text = _visibleText(document);
    final hasRequirementSummary = _containsAny(text, const [
      '学分要求',
      '总学分',
      '应修学分',
      '已修学分',
      '必修',
      '选修',
      '模块',
    ]);
    if (!hasRequirementSummary) {
      throw const SchemaMismatch('HTML 学分要求缺少已知字段',
          dataset: 'credit_requirements');
    }
    List<Map<String, dynamic>> courses;
    try {
      courses = _parseHtmlCollection(
        document,
        dataset: 'credit_requirements',
        aliases: _creditAliases,
        requiredFields: const {'course_name'},
        allowEmpty: true,
      );
    } on SchemaMismatch {
      // 允许只有模块汇总的页面；未知页面仍保持 fail-closed。
      courses = const <Map<String, dynamic>>[];
    }
    final module = <String, dynamic>{
      'id': 'local-requirements',
      'name': '学分要求',
      'module_type': 'required',
      'required_credits': null,
      'earned_credits': 0,
      'completed_course_count': courses.length,
      'status': 'unknown',
      'is_optional': false,
      'courses': courses,
    };
    return <String, dynamic>{
      'success': true,
      'source_kind': 'local_school_html',
      'parser_version': 'local-academic-v1',
      'status': 'available',
      'modules': <Map<String, dynamic>>[module],
      'improvement_courses': const <Map<String, dynamic>>[],
    };
  }

  static void _requireSuccess(
    Map<String, dynamic> map,
    String dataset, {
    bool allowMissing = false,
  }) {
    _rejectLoginValue(map, dataset);
    if (map['success'] == false || map['ok'] == false) {
      throw SchemaMismatch('学校响应报告失败', dataset: dataset);
    }
    if (!allowMissing && map['success'] != true) {
      throw SchemaMismatch('响应缺少成功标记', dataset: dataset);
    }
  }

  static void _checkEcho(
    Map<String, dynamic> row,
    String field,
    Object? expected,
    String dataset,
  ) {
    if (expected == null || row[field] == null) return;
    if (row[field].toString().trim() != expected.toString()) {
      throw SchemaMismatch('响应学期与请求不一致', dataset: dataset, field: field);
    }
  }

  static void _rejectLoginDocument(Document document, String dataset) {
    final text = _visibleText(document).toLowerCase();
    if (_looksLikeLogin(text)) {
      throw SchemaMismatch('学校会话已过期或返回登录页', dataset: dataset);
    }
  }

  static void _rejectLoginValue(Object? value, String dataset) {
    if (value is! Map) return;
    final map = Map<String, dynamic>.from(value);
    final tokens = <String>[
      map['code']?.toString() ?? '',
      map['error_code']?.toString() ?? '',
      map['status']?.toString() ?? '',
      map['message']?.toString() ?? '',
      map['error']?.toString() ?? '',
    ].join(' ').toLowerCase();
    if (_looksLikeLogin(tokens) ||
        tokens.contains('session_expired') ||
        tokens.contains('edu_session')) {
      throw SchemaMismatch('学校会话已过期', dataset: dataset);
    }
  }

  static bool _looksLikeLogin(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('login_slogin') ||
        normalized.contains('统一身份认证') ||
        normalized.contains('用户登录') ||
        normalized.contains('session_expired') ||
        normalized.contains('edu_session_expired');
  }

  static String _visibleText(Document document) {
    for (final node in document.querySelectorAll('script,style,noscript')) {
      node.remove();
    }
    return (document.body?.text ?? document.text ?? '').trim();
  }

  static String _header(String value) => value
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[：:（）()/-]'), '')
      .toLowerCase();

  static String _string(Object? value) => value?.toString().trim() ?? '';

  static Map<String, dynamic> _copyMap(Map value) =>
      Map<String, dynamic>.from(value);

  static String _rowKey(Map<String, dynamic> row, List<String> keyFields) {
    for (final field in keyFields) {
      final value = _string(row[field]);
      if (value.isNotEmpty) return '$field:$value';
    }
    return _canonicalJson(row);
  }

  static String _canonicalJson(Map<String, dynamic> row) {
    final keys = row.keys.toList()..sort();
    return jsonEncode(<String, dynamic>{for (final key in keys) key: row[key]});
  }

  static List<String> _defaultKeyFields(String dataset) => switch (dataset) {
        'grades' => const ['course_id', 'course_code', 'name'],
        'schedule' => const ['course_code', 'name', 'weekday', 'time'],
        'exams' => const ['exam_id', 'course_code', 'name', 'date'],
        _ => const ['id', 'course_code', 'course_name', 'name'],
      };

  static bool _containsAny(String text, Iterable<String> values) {
    final lower = text.toLowerCase();
    return values.any((value) => lower.contains(value.toLowerCase()));
  }

  static const Map<String, String> _gradeAliases = <String, String>{
    'name': 'name',
    '课程名称': 'name',
    '课程': 'name',
    'course_name': 'name',
    '成绩': 'grade',
    'grade': 'grade',
    '总评成绩': 'grade',
    '学分': 'credits',
    '课程学分': 'credits',
    'credits': 'credits',
    '课程号': 'course_code',
    '课程代码': 'course_code',
    'course_code': 'course_code',
    '考试性质': 'exam_type',
    '考试类型': 'exam_type',
  };

  static const Map<String, String> _scheduleAliases = <String, String>{
    'name': 'name',
    '课程名称': 'name',
    '课程': 'name',
    'course_name': 'name',
    '教师': 'teacher',
    '任课教师': 'teacher',
    'teacher': 'teacher',
    '地点': 'location',
    '上课地点': 'location',
    'location': 'location',
    '星期': 'weekday',
    '星期几': 'weekday',
    '周几': 'weekday',
    'weekday': 'weekday',
    '节次': 'time',
    '上课节次': 'time',
    'time': 'time',
    '周次': 'weeks',
    '上课周次': 'weeks',
    'weeks': 'weeks',
    '课程号': 'course_code',
    'course_code': 'course_code',
  };

  static const Map<String, String> _examAliases = <String, String>{
    'name': 'name',
    '课程名称': 'name',
    '课程': 'name',
    'course_name': 'name',
    '考试日期': 'date',
    '日期': 'date',
    'date': 'date',
    '考试时间': 'start_time',
    '时间': 'start_time',
    'start_time': 'start_time',
    '结束时间': 'end_time',
    'end_time': 'end_time',
    '考场': 'location',
    '地点': 'location',
    'location': 'location',
    '课程号': 'course_code',
    'course_code': 'course_code',
  };

  static const Map<String, String> _academicAliases = <String, String>{
    '课程名称': 'course_name',
    '课程': 'course_name',
    'course_name': 'course_name',
    '课程号': 'course_code',
    '课程代码': 'course_code',
    'course_code': 'course_code',
    '成绩': 'grade',
    'grade': 'grade',
    '学分': 'credits',
    'credits': 'credits',
  };

  static const Map<String, String> _creditAliases = <String, String>{
    '课程名称': 'course_name',
    '课程': 'course_name',
    'course_name': 'course_name',
    '课程号': 'course_code',
    '课程代码': 'course_code',
    'course_code': 'course_code',
    '课程学分': 'credits',
    '学分': 'credits',
    'credits': 'credits',
    '建议修读学年': 'suggested_year',
    '建议修读学期': 'suggested_semester',
    '实际修读学年': 'actual_year',
    '实际修读学期': 'actual_semester',
    '课程性质': 'course_nature',
    '选必修': 'course_nature',
    '成绩': 'grade',
    '修读状态': 'raw_status',
    '状态': 'raw_status',
    '备注': 'remark',
  };
}
