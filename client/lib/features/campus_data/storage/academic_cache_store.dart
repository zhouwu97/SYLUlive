import 'dart:async';

import 'account_scoped_snapshot_store.dart';
import 'personal_snapshot_models.dart';

/// 已验证来源账号的单学期成绩快照。
class AcademicTermSnapshot {
  AcademicTermSnapshot({
    required String year,
    required this.semester,
    required this.fetchedAt,
    List<Map<String, dynamic>> grades = const <Map<String, dynamic>>[],
  })  : year = year.trim(),
        grades = List<Map<String, dynamic>>.unmodifiable(
          grades.map(_copyAcademicMap),
        ) {
    if (this.year.isEmpty || semester <= 0) {
      throw ArgumentError('成绩学期参数无效');
    }
  }

  final String year;
  final int semester;
  final DateTime fetchedAt;
  final List<Map<String, dynamic>> grades;

  String get termId => '${year}_$semester';

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'year': year,
      'semester': semester,
      'fetched_at': fetchedAt.toUtc().toIso8601String(),
      'grades': grades.map(_copyAcademicMap).toList(growable: false),
    };
  }

  factory AcademicTermSnapshot.fromPayload(
    String expectedTermId,
    Map<String, dynamic> payload,
  ) {
    final year = payload['year'];
    final semester = payload['semester'];
    final fetchedAt = _parseAcademicDateTime(payload['fetched_at'], '成绩时间');
    if (year is! String ||
        year.trim().isEmpty ||
        semester is! num ||
        semester <= 0 ||
        semester % 1 != 0 ||
        '${year.trim()}_${semester.toInt()}' != expectedTermId) {
      throw const FormatException('成绩学期格式错误');
    }
    return AcademicTermSnapshot(
      year: year,
      semester: semester.toInt(),
      fetchedAt: fetchedAt,
      grades: _copyAcademicMapList(payload['grades'], '成绩列表'),
    );
  }
}

/// 服务端学业情况的加密快照，不向 Gateway 直接暴露原始课程字段。
class AcademicSituationSnapshot {
  AcademicSituationSnapshot({
    required this.fetchedAt,
    required Map<String, dynamic> data,
  }) : data = Map<String, dynamic>.unmodifiable(_copyAcademicMap(data));

  final DateTime fetchedAt;
  final Map<String, dynamic> data;

  Map<String, dynamic> toPayload() => <String, dynamic>{
        'fetched_at': fetchedAt.toUtc().toIso8601String(),
        'data': _copyAcademicMap(data),
      };

  factory AcademicSituationSnapshot.fromPayload(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is! Map) throw const FormatException('学业情况格式错误');
    return AcademicSituationSnapshot(
      fetchedAt: _parseAcademicDateTime(payload['fetched_at'], '学业情况时间'),
      data: Map<String, dynamic>.from(data),
    );
  }
}

/// 已通过本地解析的单次考试快照。
///
/// 考试接口在不同学校可能按学期返回，也可能返回全量数据；使用显式键保存
/// 请求范围，避免把一个范围的结果误当作另一个范围的完整事实。
class AcademicExamTermSnapshot {
  AcademicExamTermSnapshot({
    required this.key,
    required this.fetchedAt,
    List<Map<String, dynamic>> exams = const <Map<String, dynamic>>[],
  }) : exams = List<Map<String, dynamic>>.unmodifiable(
          exams.map(_copyAcademicMap),
        ) {
    if (key.trim().isEmpty) throw ArgumentError('考试查询范围不能为空');
  }

  final String key;
  final DateTime fetchedAt;
  final List<Map<String, dynamic>> exams;

  Map<String, dynamic> toPayload() => <String, dynamic>{
        'key': key,
        'fetched_at': fetchedAt.toUtc().toIso8601String(),
        'exams': exams.map(_copyAcademicMap).toList(growable: false),
      };

  factory AcademicExamTermSnapshot.fromPayload(
    String expectedKey,
    Map<String, dynamic> payload,
  ) {
    final key = payload['key'];
    if (key is! String || key.trim().isEmpty || key.trim() != expectedKey) {
      throw const FormatException('考试查询范围格式错误');
    }
    return AcademicExamTermSnapshot(
      key: key,
      fetchedAt: _parseAcademicDateTime(payload['fetched_at'], '考试时间'),
      exams: _copyAcademicMapList(payload['exams'], '考试列表'),
    );
  }
}

/// 从 AES-GCM 认证通过的成绩快照解析出的最小存储模型。
class AcademicVaultSnapshot {
  AcademicVaultSnapshot({
    required Map<String, AcademicTermSnapshot> terms,
    required this.fetchedAt,
    required this.expiresAt,
    required this.isStale,
    this.situation,
    this.creditRequirements,
    this.creditRequirementsFetchedAt,
    this.isGradeSyncComplete = false,
    this.examTerms = const <String, AcademicExamTermSnapshot>{},
  }) : terms = Map<String, AcademicTermSnapshot>.unmodifiable(terms);

  final Map<String, AcademicTermSnapshot> terms;
  final DateTime fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
  final AcademicSituationSnapshot? situation;
  final Map<String, dynamic>? creditRequirements;
  final DateTime? creditRequirementsFetchedAt;
  final bool isGradeSyncComplete;
  final Map<String, AcademicExamTermSnapshot> examTerms;
}

/// 成绩数据只在网络请求成功后直接写入 AES-GCM 保险箱，不创建明文迁移链路。
class AcademicCacheStore {
  AcademicCacheStore({
    required this.appUserId,
    required this.sourceAccountId,
    AccountScopedSnapshotStore? snapshotStore,
  }) : _snapshotStore = snapshotStore ??
            AesGcmAccountScopedSnapshotStore(appUserId: appUserId);

  static const int schemaVersion = 1;
  static const Duration _expiry = Duration(days: 30);

  static final Map<String, Future<void>> _mutationTails =
      <String, Future<void>>{};

  final String appUserId;
  final String sourceAccountId;
  final AccountScopedSnapshotStore _snapshotStore;

  bool get _hasValidNamespace =>
      appUserId.trim().isNotEmpty && sourceAccountId.trim().isNotEmpty;

  Future<AcademicVaultSnapshot?> readSnapshot() async {
    if (!_hasValidNamespace) return null;
    final encryptedSnapshot = await _snapshotStore.read(
      type: PersonalDataType.academic,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
    );
    if (encryptedSnapshot == null) return null;
    if (encryptedSnapshot.schemaVersion != schemaVersion) {
      throw const PersonalSnapshotStoreException('成绩密文快照版本不受支持');
    }
    final payload = encryptedSnapshot.payload;

    final rawTerms = payload['grade_terms'];
    if (rawTerms is! Map) {
      throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
    }
    final terms = <String, AcademicTermSnapshot>{};
    for (final entry in rawTerms.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
      }
      try {
        terms[entry.key as String] = AcademicTermSnapshot.fromPayload(
          entry.key as String,
          Map<String, dynamic>.from(entry.value as Map),
        );
      } on FormatException {
        throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
      }
    }

    final rawSituation = payload['academic_situation'];
    if (rawSituation != null && rawSituation is! Map) {
      throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
    }
    final rawExamTerms = payload['exam_terms'];
    if (rawExamTerms != null && rawExamTerms is! Map) {
      throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
    }
    final examTerms = <String, AcademicExamTermSnapshot>{};
    if (rawExamTerms is Map) {
      for (final entry in rawExamTerms.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
        }
        try {
          final key = entry.key as String;
          examTerms[key] = AcademicExamTermSnapshot.fromPayload(
            key,
            Map<String, dynamic>.from(entry.value as Map),
          );
        } on FormatException {
          throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
        }
      }
    }
    try {
      return AcademicVaultSnapshot(
        terms: terms,
        fetchedAt: encryptedSnapshot.fetchedAt,
        expiresAt: encryptedSnapshot.expiresAt,
        isStale: encryptedSnapshot.isStale,
        situation: rawSituation == null
            ? null
            : AcademicSituationSnapshot.fromPayload(
                Map<String, dynamic>.from(rawSituation as Map),
              ),
        creditRequirements: payload['credit_requirements'] is Map
            ? Map<String, dynamic>.from(payload['credit_requirements'] as Map)
            : null,
        creditRequirementsFetchedAt:
            payload['credit_requirements_fetched_at'] is String
                ? DateTime.tryParse(
                    payload['credit_requirements_fetched_at'] as String,
                  )?.toUtc()
                : null,
        isGradeSyncComplete: payload['grade_sync_complete'] == true,
        examTerms: examTerms,
      );
    } on FormatException {
      throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
    }
  }

  Future<void> writeGrades({
    required String year,
    required int semester,
    required List<Map<String, dynamic>> grades,
    DateTime? fetchedAt,
  }) async {
    _validateNamespace();
    final record = AcademicTermSnapshot(
      year: year,
      semester: semester,
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
      grades: _copyAcademicMapList(grades, '成绩列表'),
    );
    await _serializeMutation(() async {
      final payload = await _readPayload() ?? _emptyPayload();
      final rawTerms = payload['grade_terms'];
      if (rawTerms is! Map) {
        throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
      }
      final terms = Map<String, dynamic>.from(rawTerms);
      terms[record.termId] = record.toPayload();
      payload['grade_terms'] = terms;
      await _writePayload(payload);
    });
  }

  Future<void> writeAcademicSituation({
    required Map<String, dynamic> data,
    DateTime? fetchedAt,
  }) async {
    _validateNamespace();
    final record = AcademicSituationSnapshot(
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
      data: _copyAcademicMap(data),
    );
    await _serializeMutation(() async {
      final payload = await _readPayload() ?? _emptyPayload();
      payload['academic_situation'] = record.toPayload();
      await _writePayload(payload);
    });
  }

  /// 只有所有有效学期均成功请求后才写入完成标记，防止局部成绩被当成完整 GPA 数据。
  Future<void> markGradeSyncComplete() async {
    _validateNamespace();
    await _serializeMutation(() async {
      final payload = await _readPayload() ?? _emptyPayload();
      payload['grade_sync_complete'] = true;
      await _writePayload(payload);
    });
  }

  /// 写入学分要求数据到加密快照。
  Future<void> writeCreditRequirements({
    required Map<String, dynamic> data,
    DateTime? fetchedAt,
  }) async {
    _validateNamespace();
    final capturedAt = fetchedAt ?? DateTime.now().toUtc();
    await _serializeMutation(() async {
      final payload = await _readPayload() ?? _emptyPayload();
      payload['credit_requirements'] = _copyAcademicMap(data);
      payload['credit_requirements_fetched_at'] =
          capturedAt.toUtc().toIso8601String();
      await _writePayload(payload);
    });
  }

  /// 将本地解析后的考试数据写入加密快照。
  ///
  /// [year] 与 [semester] 必须同时提供或同时省略。省略时使用 `all` 键，
  /// 供学校返回全量考试的接口使用；不会把不同查询范围静默合并。
  Future<void> writeExams({
    String? year,
    int? semester,
    required List<Map<String, dynamic>> exams,
    DateTime? fetchedAt,
  }) async {
    _validateNamespace();
    final key = _examKey(year, semester);
    final record = AcademicExamTermSnapshot(
      key: key,
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
      exams: _copyAcademicMapList(exams, '考试列表'),
    );
    await _serializeMutation(() async {
      final payload = await _readPayload() ?? _emptyPayload();
      final rawTerms = payload['exam_terms'];
      if (rawTerms is! Map) {
        throw const PersonalSnapshotStoreException('成绩密文快照格式错误');
      }
      final terms = Map<String, dynamic>.from(rawTerms);
      terms[key] = record.toPayload();
      payload['exam_terms'] = terms;
      await _writePayload(payload);
    });
  }

  /// 读取指定查询范围的考试快照；不存在时返回 null。
  Future<List<Map<String, dynamic>>?> readExams({
    String? year,
    int? semester,
  }) async {
    final snapshot = await readSnapshot();
    final record = snapshot?.examTerms[_examKey(year, semester)];
    return record?.exams.map(_copyAcademicMap).toList(growable: false);
  }

  Future<void> clearAll() async {
    _validateNamespace();
    await _serializeMutation(
      () => _snapshotStore.deleteType(PersonalDataType.academic),
    );
  }

  Future<void> close() => _snapshotStore.close();

  Future<Map<String, dynamic>?> _readPayload() async {
    final snapshot = await _snapshotStore.read(
      type: PersonalDataType.academic,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
    );
    if (snapshot == null) return null;
    if (snapshot.schemaVersion != schemaVersion) {
      throw const PersonalSnapshotStoreException('成绩密文快照版本不受支持');
    }
    return Map<String, dynamic>.from(snapshot.payload);
  }

  Map<String, dynamic> _emptyPayload() => <String, dynamic>{
        'grade_terms': <String, dynamic>{},
        'exam_terms': <String, dynamic>{},
        'academic_situation': null,
        'credit_requirements': null,
        'credit_requirements_fetched_at': null,
        'grade_sync_complete': false,
      };

  Future<void> _writePayload(Map<String, dynamic> payload) async {
    final now = DateTime.now().toUtc();
    await _snapshotStore.write(
      type: PersonalDataType.academic,
      schemaVersion: schemaVersion,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
      fetchedAt: now,
      expiresAt: now.add(_expiry),
      payload: payload,
    );
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final queueKey =
        '${_snapshotStore.accountFingerprint}/${PersonalDataType.academic.storageValue}';
    final previous = _mutationTails[queueKey] ?? Future<void>.value();
    final guarded = previous.then<T>((_) => operation());
    final tail = guarded.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _mutationTails[queueKey] = tail;
    return guarded.whenComplete(() {
      if (identical(_mutationTails[queueKey], tail)) {
        _mutationTails.remove(queueKey);
      }
    });
  }

  void _validateNamespace() {
    if (!_hasValidNamespace) {
      throw StateError('成绩缓存缺少有效的账号命名空间');
    }
  }

  String _examKey(String? year, int? semester) {
    if (year == null && semester == null) return 'all';
    final normalizedYear = year?.trim() ?? '';
    if (normalizedYear.isEmpty || semester == null || semester <= 0) {
      throw ArgumentError('考试查询范围参数无效');
    }
    return '${normalizedYear}_$semester';
  }
}

Map<String, dynamic> _copyAcademicMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(value);

List<Map<String, dynamic>> _copyAcademicMapList(Object? raw, String fieldName) {
  if (raw is! Iterable) throw FormatException('$fieldName格式错误');
  return raw.map((value) {
    if (value is! Map) throw FormatException('$fieldName格式错误');
    return Map<String, dynamic>.from(value);
  }).toList(growable: false);
}

DateTime _parseAcademicDateTime(Object? value, String fieldName) {
  if (value is! String) throw FormatException('$fieldName格式错误');
  final parsed = DateTime.tryParse(value)?.toUtc();
  if (parsed == null) throw FormatException('$fieldName格式错误');
  return parsed;
}
