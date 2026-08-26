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
  }) : terms = Map<String, AcademicTermSnapshot>.unmodifiable(terms);

  final Map<String, AcademicTermSnapshot> terms;
  final DateTime fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
  final AcademicSituationSnapshot? situation;
  final Map<String, dynamic>? creditRequirements;
  final DateTime? creditRequirementsFetchedAt;
  final bool isGradeSyncComplete;
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
