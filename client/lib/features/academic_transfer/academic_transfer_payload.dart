import 'dart:convert';

/// 二维码内容：`https://<站点>/web/app-scan#v=1&s=<会话>&k=<公钥>`，
/// 或落地页「在 App 中打开」使用的 `sylulive://academic-transfer?v=1&s=..&k=..`。
///
/// 只取会话与公钥；二维码里的主机名不参与请求，App 始终访问自己配置的服务器，
/// 所以伪造的二维码无法把资料引到别处。
class AcademicTransferLink {
  const AcademicTransferLink(
      {required this.sessionId, required this.webPublicKey});

  final String sessionId;
  final String webPublicKey;

  static final RegExp _session = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
  static final RegExp _key = RegExp(r'^[A-Za-z0-9_-]{80,96}$');

  static AcademicTransferLink? tryParse(String? raw) {
    final uri = Uri.tryParse(raw?.trim() ?? '');
    if (uri == null) return null;
    final String query;
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.path == '/web/app-scan') {
      query = uri.fragment;
    } else if (uri.scheme == 'sylulive' && uri.host == 'academic-transfer') {
      query = uri.query;
    } else {
      return null;
    }
    final Map<String, String> params;
    try {
      params = Uri.splitQueryString(query);
    } catch (_) {
      return null;
    }
    final session = params['s'] ?? '', key = params['k'] ?? '';
    if (params['v'] != '1' ||
        !_session.hasMatch(session) ||
        !_key.hasMatch(key)) {
      return null;
    }
    return AcademicTransferLink(sessionId: session, webPublicKey: key);
  }
}

/// 可选择同步的资料类型。
enum AcademicTransferPart { schedules, grades, exams, erke, physical }

/// 一份待同步的课表：手机当前使用的、缓存中的其他学期或用户存档。
class AcademicTransferSchedule {
  const AcademicTransferSchedule({
    required this.id,
    required this.kind,
    required this.label,
    required this.courses,
    this.provider = '',
    this.year,
    this.semester,
    this.termStart,
    this.fetchedAt,
  });

  final String id;

  /// current / term / archive，与网页解析器约定一致。
  final String kind;
  final String label;
  final String provider;
  final String? year;
  final int? semester;
  final DateTime? termStart;
  final DateTime? fetchedAt;
  final List<Map<String, dynamic>> courses;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'label': label,
        'provider': provider,
        if (year != null && semester != null)
          'term': <String, String>{'year': year!, 'semester': '$semester'},
        if (termStart != null) 'termStart': _date(termStart!),
        if (fetchedAt != null)
          'fetchedAt': fetchedAt!.toUtc().toIso8601String(),
        'courses': courses,
      };
}

/// 从本机加密缓存读出的、尚未按用户选择裁剪的资料。
class AcademicTransferBundle {
  const AcademicTransferBundle({
    this.schedules = const <AcademicTransferSchedule>[],
    this.grades = const <Map<String, dynamic>>[],
    this.gradesFetchedAt,
    this.exams = const <Map<String, dynamic>>[],
    this.erke,
    this.physical,
  });

  final List<AcademicTransferSchedule> schedules;
  final List<Map<String, dynamic>> grades;
  final DateTime? gradesFetchedAt;
  final List<Map<String, dynamic>> exams;
  final Map<String, dynamic>? erke;
  final Map<String, dynamic>? physical;

  int count(AcademicTransferPart part) => switch (part) {
        AcademicTransferPart.schedules =>
          schedules.where((item) => item.courses.isNotEmpty).length,
        AcademicTransferPart.grades => grades.length,
        AcademicTransferPart.exams => exams.length,
        AcademicTransferPart.erke => erke == null ? 0 : 1,
        AcademicTransferPart.physical =>
          (physical?['years'] as List?)?.length ?? 0,
      };

  bool get isEmpty =>
      AcademicTransferPart.values.every((part) => count(part) == 0);

  /// 按用户勾选生成明文 JSON；只写入网页解析器认识的字段。
  List<int> encode(Set<AcademicTransferPart> parts, {DateTime? now}) {
    final payload = <String, dynamic>{
      'version': 1,
      'generatedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      if (parts.contains(AcademicTransferPart.schedules))
        'schedules': schedules
            .where((item) => item.courses.isNotEmpty)
            .map((item) => item.toJson())
            .toList(),
      if (parts.contains(AcademicTransferPart.grades) && grades.isNotEmpty)
        'grades': <String, dynamic>{
          if (gradesFetchedAt != null)
            'fetchedAt': gradesFetchedAt!.toUtc().toIso8601String(),
          'items': grades,
        },
      if (parts.contains(AcademicTransferPart.exams) && exams.isNotEmpty)
        'exams': <String, dynamic>{'items': exams},
      if (parts.contains(AcademicTransferPart.erke) && erke != null)
        'erke': erke,
      if (parts.contains(AcademicTransferPart.physical) && physical != null)
        'physical': physical,
    };
    return utf8.encode(jsonEncode(payload));
  }
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _text(Object? value) => value?.toString().trim() ?? '';

int? _int(Object? value) => switch (value) {
      int v => v,
      num v when v % 1 == 0 => v.toInt(),
      String v => int.tryParse(v.trim()),
      _ => null,
    };

double? _double(Object? value) => switch (value) {
      num v => v.toDouble(),
      String v => double.tryParse(v.trim()),
      _ => null,
    };

/// 把 App 课表格子（CourseBlock JSON）转换成网页课程；节次展开为连续列表。
/// 字段不完整的课程直接丢弃，不猜测补齐。
Map<String, dynamic>? transferCourseFromBlock(
    Map<String, dynamic> block, int index) {
  final name = _text(block['custom_name'] ?? block['name']);
  final day = _int(block['weekday']);
  final start = _int(block['start_section']);
  final end = _int(block['end_section']) ?? start;
  final weeks = (block['weeks'] is List ? block['weeks'] as List : const [])
      .map(_int)
      .whereType<int>()
      .where((week) => week >= 1 && week <= 60)
      .toSet()
      .toList()
    ..sort();
  if (name.isEmpty ||
      day == null ||
      day < 1 ||
      day > 7 ||
      start == null ||
      end == null ||
      start < 1 ||
      end < start ||
      end > 20 ||
      weeks.isEmpty) {
    return null;
  }
  final key = <String>[_text(block['course_key']), _text(block['meeting_key'])]
      .where((part) => part.isNotEmpty)
      .join(':');
  final id = key.isNotEmpty
      ? key
      : (_text(block['id']).isNotEmpty
          ? 'app:${_text(block['id'])}'
          : 'app:$index');
  return <String, dynamic>{
    'id': id,
    'name': name,
    'teacher': _text(block['teacher']),
    'room': _text(block['location'] ?? block['room']),
    'day': day,
    'periods': <int>[for (var p = start; p <= end; p++) p],
    'weeks': weeks,
  };
}

List<Map<String, dynamic>> transferCourses(
    Iterable<Map<String, dynamic>> blocks) {
  final result = <Map<String, dynamic>>[];
  var index = 0;
  for (final block in blocks) {
    final course = transferCourseFromBlock(block, index++);
    if (course != null) result.add(course);
  }
  return result;
}

String transferTermLabel(String year, int semester) {
  final start = int.tryParse(year);
  final name = switch (semester) {
    3 => '第一学期',
    12 => '第二学期',
    16 => '第三学期',
    _ => '学期 $semester'
  };
  return start == null ? '$year $name' : '$start-${start + 1} $name';
}

/// 成绩：保留展示和绩点统计需要的最少字段，不带教学班、成绩单令牌等教务内部标识。
Map<String, dynamic>? transferGrade(
    Map<String, dynamic> raw, String termLabel, int index) {
  final name = _text(raw['name'] ?? raw['course_name']);
  final credit = _double(raw['credits'] ?? raw['credit']);
  if (name.isEmpty || credit == null || credit < 0) return null;
  final grade = _text(raw['grade']);
  final fraction = _double(raw['fraction']);
  final score = grade.isNotEmpty && grade != '--'
      ? grade
      : fraction == null
          ? ''
          : fraction.toString();
  final code = _text(raw['course_id']).isNotEmpty
      ? _text(raw['course_id'])
      : _text(raw['course_code']);
  return <String, dynamic>{
    'id': code.isEmpty ? 'app:$termLabel:$index' : '$code:$termLabel',
    'name': name,
    'credit': credit,
    'score': score,
    'gpa': _double(raw['gpa']),
    'nature': _text(raw['course_nature'] ?? raw['course_category']),
    'term': termLabel,
  };
}

Map<String, dynamic> transferErke(Map<String, dynamic> snapshot) {
  final graduation = snapshot['graduation'] is Map
      ? Map<String, dynamic>.from(snapshot['graduation'] as Map)
      : const <String, dynamic>{};
  final categories = (graduation['categories'] is List
          ? graduation['categories'] as List
          : const [])
      .whereType<Map>()
      .map((item) => <String, dynamic>{
            'code': _text(item['code']),
            'name': _text(item['name']),
            'required': _double(item['required']) ?? 0,
            'earned': _double(item['earned']) ?? 0,
          })
      .where((item) => (item['name'] as String).isNotEmpty)
      .toList();
  final activities = (snapshot['activities'] is List
          ? snapshot['activities'] as List
          : const [])
      .whereType<Map>()
      .map((item) => <String, dynamic>{
            'item': _text(item['item']),
            'score': _text(item['score']),
            'date': _text(item['date']),
            'category': _text(item['category']),
          })
      .where((item) => (item['item'] as String).isNotEmpty)
      .toList();
  return <String, dynamic>{
    if (snapshot['fetchedAt'] != null)
      'fetchedAt': _text(snapshot['fetchedAt']),
    'requiredTotal': _double(graduation['requiredTotal']),
    'earnedTotal': _double(graduation['earnedTotal']),
    'graduationGap': _double(graduation['graduationGap']),
    'conclusion': _text(graduation['officialConclusion']),
    'categories': categories,
    'activities': activities,
  };
}

Map<String, dynamic>? transferPhysical(
    Map<String, dynamic> payload, DateTime? fetchedAt) {
  final rawYears = payload['years'];
  if (rawYears is! Map || rawYears.isEmpty) return null;
  final years = rawYears.entries
      .where((entry) => entry.value is Map && _text(entry.key).isNotEmpty)
      .map((entry) {
    final value = Map<String, dynamic>.from(entry.value as Map);
    final scores =
        (value['scores'] is List ? value['scores'] as List : const [])
            .whereType<Map>()
            .map((score) => <String, dynamic>{
                  'name': _text(score['sub_name']),
                  'result': _text(score['result']),
                  'grade': _text(score['grade']),
                  'score': _double(score['score']),
                })
            .where((score) => (score['name'] as String).isNotEmpty)
            .toList();
    return <String, dynamic>{
      'year': _text(entry.key),
      'totalScore': _double(value['total_score']),
      'totalGrade': _text(value['total_grade']),
      'scores': scores,
    };
  }).toList()
    ..sort((left, right) =>
        (right['year'] as String).compareTo(left['year'] as String));
  if (years.isEmpty) return null;
  return <String, dynamic>{
    if (fetchedAt != null) 'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'years': years,
  };
}
