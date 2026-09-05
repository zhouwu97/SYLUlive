import 'dart:async';

import 'account_cache_namespace.dart';
import 'account_scoped_snapshot_store.dart';
import 'personal_snapshot_models.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

import '../../academic/storage/academic_persistence_gate.dart';

/// 已验证来源账号的单学期课表快照。
///
/// 课程、隐藏状态、学期起始日期和用户创建的存档共同保存在同一份加密
/// schedule 快照中，避免把任一部分继续落入明文偏好设置。
class ScheduleTermSnapshot {
  ScheduleTermSnapshot({
    List<Map<String, dynamic>> courses = const <Map<String, dynamic>>[],
    List<int> hiddenCourseIds = const <int>[],
    this.semesterStart,
    List<ScheduleArchiveSnapshot> archives = const <ScheduleArchiveSnapshot>[],
    this.activeArchiveId,
  })  : courses =
            List<Map<String, dynamic>>.unmodifiable(courses.map(_copyMap)),
        hiddenCourseIds = List<int>.unmodifiable(hiddenCourseIds),
        archives = List<ScheduleArchiveSnapshot>.unmodifiable(archives);

  final List<Map<String, dynamic>> courses;
  final List<int> hiddenCourseIds;
  final DateTime? semesterStart;
  final List<ScheduleArchiveSnapshot> archives;
  final String? activeArchiveId;

  ScheduleTermSnapshot copyWith({
    List<Map<String, dynamic>>? courses,
    List<int>? hiddenCourseIds,
    DateTime? semesterStart,
    bool clearSemesterStart = false,
    List<ScheduleArchiveSnapshot>? archives,
    String? activeArchiveId,
    bool clearActiveArchive = false,
  }) {
    return ScheduleTermSnapshot(
      courses: courses ?? this.courses,
      hiddenCourseIds: hiddenCourseIds ?? this.hiddenCourseIds,
      semesterStart:
          clearSemesterStart ? null : (semesterStart ?? this.semesterStart),
      archives: archives ?? this.archives,
      activeArchiveId:
          clearActiveArchive ? null : (activeArchiveId ?? this.activeArchiveId),
    );
  }

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'courses': courses.map(_copyMap).toList(growable: false),
      'hidden_course_ids': List<int>.from(hiddenCourseIds),
      'semester_start': semesterStart?.toUtc().toIso8601String(),
      'archives': archives.map((archive) => archive.toPayload()).toList(),
      'active_archive_id': activeArchiveId,
    };
  }

  factory ScheduleTermSnapshot.fromPayload(Map<String, dynamic> payload) {
    final courses = _copyMapList(payload['courses'], '课程');
    final hiddenCourseIds = _copyIntList(payload['hidden_course_ids'], '隐藏课程');
    final semesterStart = _parseOptionalDateTime(
      payload['semester_start'],
      '学期起始日期',
    );

    final rawArchives = payload['archives'];
    if (rawArchives != null && rawArchives is! List) {
      throw const FormatException('课表存档格式错误');
    }
    final archives = <ScheduleArchiveSnapshot>[];
    for (final rawArchive in rawArchives ?? const <dynamic>[]) {
      if (rawArchive is! Map) {
        throw const FormatException('课表存档格式错误');
      }
      archives.add(
        ScheduleArchiveSnapshot.fromPayload(
          Map<String, dynamic>.from(rawArchive),
        ),
      );
    }

    final rawActiveArchiveId = payload['active_archive_id'];
    if (rawActiveArchiveId != null && rawActiveArchiveId is! String) {
      throw const FormatException('课表活动存档格式错误');
    }
    final activeArchiveId = (rawActiveArchiveId as String?)?.trim();
    if (activeArchiveId != null &&
        activeArchiveId.isNotEmpty &&
        !archives.any((archive) => archive.id == activeArchiveId)) {
      throw const FormatException('课表活动存档归属错误');
    }

    return ScheduleTermSnapshot(
      courses: courses,
      hiddenCourseIds: hiddenCourseIds,
      semesterStart: semesterStart,
      archives: archives,
      activeArchiveId: activeArchiveId == null || activeArchiveId.isEmpty
          ? null
          : activeArchiveId,
    );
  }
}

/// 加密课表中的用户存档，包含元数据和对应课程，不单独落地到明文缓存。
class ScheduleArchiveSnapshot {
  ScheduleArchiveSnapshot({
    required String id,
    required String name,
    required this.createdAt,
    required this.courseCount,
    List<Map<String, dynamic>> courses = const <Map<String, dynamic>>[],
  })  : id = id.trim(),
        name = name.trim(),
        courses = List<Map<String, dynamic>>.unmodifiable(
          courses.map(_copyMap),
        ) {
    if (this.id.isEmpty || this.name.isEmpty || courseCount < 0) {
      throw ArgumentError('课表存档参数无效');
    }
  }

  final String id;
  final String name;
  final DateTime createdAt;
  final int courseCount;
  final List<Map<String, dynamic>> courses;

  ScheduleArchiveSnapshot copyWith({String? name}) {
    return ScheduleArchiveSnapshot(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      courseCount: courseCount,
      courses: courses,
    );
  }

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'created_at': createdAt.toUtc().toIso8601String(),
      'course_count': courseCount,
      'courses': courses.map(_copyMap).toList(growable: false),
    };
  }

  factory ScheduleArchiveSnapshot.fromPayload(Map<String, dynamic> payload) {
    final id = payload['id'];
    final name = payload['name'];
    final createdAt = _parseRequiredDateTime(payload['created_at'], '课表存档时间');
    final courseCount = payload['course_count'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        courseCount is! num ||
        courseCount < 0 ||
        courseCount % 1 != 0) {
      throw const FormatException('课表存档格式错误');
    }
    return ScheduleArchiveSnapshot(
      id: id,
      name: name,
      createdAt: createdAt,
      courseCount: courseCount.toInt(),
      courses: _copyMapList(payload['courses'], '课表存档课程'),
    );
  }
}

/// 从 AES-GCM 认证通过的课表快照解析出的完整学期集合。
class ScheduleVaultSnapshot {
  ScheduleVaultSnapshot({
    required Map<String, ScheduleTermSnapshot> terms,
    required this.fetchedAt,
    required this.expiresAt,
    required this.isStale,
  }) : terms = Map<String, ScheduleTermSnapshot>.unmodifiable(terms);

  final Map<String, ScheduleTermSnapshot> terms;
  final DateTime fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
}

/// 课表个人数据存储。
///
/// 旧 AppPreferencesStore 课表键不含来源学号，因此无法可靠证明归属。本类只会
/// 清理这些键并设置重新同步标记，绝不把它们迁入当前来源账号的保险箱。
class ScheduleCacheStore {
  ScheduleCacheStore({
    required this.appUserId,
    required this.sourceAccountId,
    AccountScopedSnapshotStore? snapshotStore,
    Future<AppPreferencesStore> Function()? preferencesLoader,
    this.persistenceGate,
  })  : _snapshotStore = snapshotStore ??
            AesGcmAccountScopedSnapshotStore(appUserId: appUserId),
        _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

  static const int schemaVersion = 1;
  static const Duration _expiry = Duration(days: 14);

  static final Map<String, Future<void>> _mutationTails =
      <String, Future<void>>{};

  final String appUserId;
  final String sourceAccountId;
  final AccountScopedSnapshotStore _snapshotStore;
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  final AcademicPersistenceGate? persistenceGate;

  bool get _hasValidNamespace =>
      appUserId.trim().isNotEmpty && sourceAccountId.trim().isNotEmpty;

  Future<ScheduleVaultSnapshot?> readSnapshot() async {
    if (!_hasValidNamespace) return null;
    if (persistenceGate != null) {
      await AcademicPersistenceRegistry.waitUntilReady(appUserId);
    }
    final canRead = persistenceGate?.allowPersonalDataRead ?? true;
    if (!canRead) {
      return null;
    }
    final encryptedSnapshot = await _snapshotStore.read(
      type: PersonalDataType.schedule,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
    );
    if (encryptedSnapshot == null) return null;
    if (encryptedSnapshot.schemaVersion != schemaVersion) {
      throw const PersonalSnapshotStoreException('课表密文快照版本不受支持');
    }
    final rawTerms = encryptedSnapshot.payload['terms'];
    if (rawTerms is! Map) {
      throw const PersonalSnapshotStoreException('课表密文快照格式错误');
    }
    final terms = Map<String, dynamic>.from(rawTerms);
    if (terms.isEmpty) return null;

    final parsed = <String, ScheduleTermSnapshot>{};
    for (final entry in terms.entries) {
      if (!_isTermId(entry.key) || entry.value is! Map) {
        throw const PersonalSnapshotStoreException('课表密文快照格式错误');
      }
      try {
        parsed[entry.key] = ScheduleTermSnapshot.fromPayload(
          Map<String, dynamic>.from(entry.value as Map),
        );
      } on FormatException {
        throw const PersonalSnapshotStoreException('课表密文快照格式错误');
      }
    }
    return ScheduleVaultSnapshot(
      terms: parsed,
      fetchedAt: encryptedSnapshot.fetchedAt,
      expiresAt: encryptedSnapshot.expiresAt,
      isStale: encryptedSnapshot.isStale,
    );
  }

  Future<ScheduleTermSnapshot?> readTerm({
    required String year,
    required int semester,
  }) async {
    final snapshot = await readSnapshot();
    return snapshot?.terms[_termId(year, semester)];
  }

  Future<void> writeCourses({
    required String year,
    required int semester,
    required List<Map<String, dynamic>> courses,
  }) {
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) =>
          current.copyWith(courses: _copyMapList(courses, '课程')),
      clearNeedsResync: true,
    );
  }

  Future<void> writeHiddenCourseIds({
    required String year,
    required int semester,
    required Iterable<int> hiddenCourseIds,
  }) {
    final ids = hiddenCourseIds.where((id) => id > 0).toSet().toList()..sort();
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) => current.copyWith(hiddenCourseIds: ids),
    );
  }

  Future<void> writeSemesterStart({
    required String year,
    required int semester,
    required DateTime semesterStart,
  }) {
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) => current.copyWith(
        semesterStart: DateTime.utc(
          semesterStart.year,
          semesterStart.month,
          semesterStart.day,
        ),
      ),
    );
  }

  Future<void> clearActiveArchive({
    required String year,
    required int semester,
  }) {
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) => current.copyWith(clearActiveArchive: true),
    );
  }

  Future<void> saveArchive({
    required String year,
    required int semester,
    required ScheduleArchiveSnapshot archive,
  }) {
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) {
        final archives = <ScheduleArchiveSnapshot>[
          archive,
          ...current.archives.where((item) => item.id != archive.id),
        ];
        return current.copyWith(archives: archives);
      },
    );
  }

  Future<void> deleteArchive({
    required String year,
    required int semester,
    required String archiveId,
  }) {
    final normalizedId = archiveId.trim();
    if (normalizedId.isEmpty) return Future<void>.value();
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) => current.copyWith(
        archives: current.archives
            .where((archive) => archive.id != normalizedId)
            .toList(growable: false),
        clearActiveArchive: current.activeArchiveId == normalizedId,
      ),
    );
  }

  Future<void> renameArchive({
    required String year,
    required int semester,
    required String archiveId,
    required String newName,
  }) {
    final normalizedId = archiveId.trim();
    final normalizedName = newName.trim();
    if (normalizedId.isEmpty || normalizedName.isEmpty) {
      return Future<void>.value();
    }
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) => current.copyWith(
        archives: current.archives
            .map(
              (archive) => archive.id == normalizedId
                  ? archive.copyWith(name: normalizedName)
                  : archive,
            )
            .toList(growable: false),
      ),
    );
  }

  Future<void> activateArchive({
    required String year,
    required int semester,
    required String archiveId,
  }) {
    final normalizedId = archiveId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(archiveId, 'archiveId');
    }
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) {
        if (!current.archives.any((archive) => archive.id == normalizedId)) {
          throw const PersonalSnapshotStoreException('课表存档不存在');
        }
        return current.copyWith(activeArchiveId: normalizedId);
      },
    );
  }

  Future<void> clearCourses({required String year, required int semester}) {
    return _mutateTerm(
      year: year,
      semester: semester,
      update: (current) => current.copyWith(
        courses: const <Map<String, dynamic>>[],
        clearActiveArchive: true,
      ),
    );
  }

  Future<bool> needsResync() async {
    if (appUserId.trim().isEmpty) return true;
    final preferences = await _preferencesLoader();
    return preferences.getBool(
          AccountCacheNamespace.scheduleNeedsResync(appUserId),
        ) ??
        false;
  }

  /// 清理无法验证来源归属的旧课表明文。
  Future<void> discardUnownedLegacy() async {
    if (!_hasValidNamespace) return;
    final preferences = await _preferencesLoader();
    final userId = appUserId.trim();
    final prefixes = <String>[
      'course_cache_v5_${userId}_',
      'course_hidden_v5_${userId}_',
      'course_archives_v2_${userId}_',
      'active_archive_v2_${userId}_',
      'semester_start_v2_${userId}_',
    ];

    final keys = <String>{
      ...preferences.getKeys().where((key) => prefixes.any(key.startsWith)),
      ...preferences.getKeys().where(
            (key) => key.startsWith('course_archive_data_v2_'),
          ),
    };
    if (preferences.containsKey('semester_start')) {
      keys.add('semester_start');
    }

    var discarded = false;
    for (final key in keys) {
      discarded = await preferences.remove(key) || discarded;
    }
    if (discarded) await _markNeedsResync(preferences);
  }

  Future<void> close() => _snapshotStore.close();

  Future<void> _mutateTerm({
    required String year,
    required int semester,
    required ScheduleTermSnapshot Function(ScheduleTermSnapshot current) update,
    bool clearNeedsResync = false,
  }) async {
    if (persistenceGate != null) {
      await AcademicPersistenceRegistry.waitUntilReady(appUserId);
    }
    final canWrite = persistenceGate?.allowPersonalDataPersistence ?? true;
    if (!canWrite) {
      return;
    }
    if (!_hasValidNamespace) {
      throw StateError('课表缓存缺少有效的账号命名空间');
    }
    final termId = _termId(year, semester);
    await _serializeMutation(() async {
      final terms = await _readTerms();
      final rawCurrent = terms[termId];
      if (rawCurrent != null && rawCurrent is! Map) {
        throw const PersonalSnapshotStoreException('课表密文快照格式错误');
      }
      final current = rawCurrent == null
          ? ScheduleTermSnapshot()
          : ScheduleTermSnapshot.fromPayload(
              Map<String, dynamic>.from(rawCurrent as Map),
            );
      terms[termId] = update(current).toPayload();
      await _writeTerms(terms);
    });
    if (clearNeedsResync) await _clearNeedsResync();
  }

  Future<Map<String, dynamic>> _readTerms() async {
    if (persistenceGate != null) {
      await AcademicPersistenceRegistry.waitUntilReady(appUserId);
    }
    final snapshot = await _snapshotStore.read(
      type: PersonalDataType.schedule,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
    );
    if (snapshot == null) return <String, dynamic>{};
    if (snapshot.schemaVersion != schemaVersion) {
      throw const PersonalSnapshotStoreException('课表密文快照版本不受支持');
    }
    final terms = snapshot.payload['terms'];
    if (terms is! Map) {
      throw const PersonalSnapshotStoreException('课表密文快照格式错误');
    }
    return Map<String, dynamic>.from(terms);
  }

  Future<void> _writeTerms(Map<String, dynamic> terms) async {
    if (terms.isEmpty) {
      await _snapshotStore.deleteType(PersonalDataType.schedule);
      return;
    }
    final now = DateTime.now().toUtc();
    await _snapshotStore.write(
      type: PersonalDataType.schedule,
      schemaVersion: schemaVersion,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
      fetchedAt: now,
      expiresAt: now.add(_expiry),
      payload: <String, dynamic>{'terms': terms},
    );
  }

  /// 仅删除教务课表类型，不影响体测、二课等其他个人数据。
  Future<void> clearAll() async {
    if (appUserId.trim().isEmpty) return;
    await _serializeMutation(
      () => _snapshotStore.deleteType(PersonalDataType.schedule),
    );
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final queueKey =
        '${_snapshotStore.accountFingerprint}/${PersonalDataType.schedule.storageValue}';
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

  String _termId(String year, int semester) {
    final normalizedYear = year.trim();
    if (normalizedYear.isEmpty || semester <= 0) {
      throw ArgumentError('课表学期参数无效');
    }
    return '${normalizedYear}_$semester';
  }

  bool _isTermId(String value) => RegExp(r'^.+_[1-9][0-9]*$').hasMatch(value);

  Future<void> _clearNeedsResync() async {
    if (appUserId.trim().isEmpty) return;
    final preferences = await _preferencesLoader();
    await preferences.remove(
      AccountCacheNamespace.scheduleNeedsResync(appUserId),
    );
  }

  Future<void> _markNeedsResync(AppPreferencesStore preferences) {
    return preferences.setBool(
      AccountCacheNamespace.scheduleNeedsResync(appUserId),
      true,
    );
  }
}

Map<String, dynamic> _copyMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(value);

List<Map<String, dynamic>> _copyMapList(Object? raw, String fieldName) {
  if (raw == null) return <Map<String, dynamic>>[];
  if (raw is! Iterable) throw FormatException('$fieldName格式错误');
  return raw.map((value) {
    if (value is! Map) throw FormatException('$fieldName格式错误');
    return Map<String, dynamic>.from(value);
  }).toList(growable: false);
}

List<int> _copyIntList(Object? raw, String fieldName) {
  if (raw == null) return <int>[];
  if (raw is! Iterable) throw FormatException('$fieldName格式错误');
  final values = <int>{};
  for (final value in raw) {
    if (value is! num || value % 1 != 0 || value <= 0) {
      throw FormatException('$fieldName格式错误');
    }
    values.add(value.toInt());
  }
  return values.toList()..sort();
}

DateTime? _parseOptionalDateTime(Object? value, String fieldName) {
  if (value == null) return null;
  return _parseRequiredDateTime(value, fieldName);
}

DateTime _parseRequiredDateTime(Object? value, String fieldName) {
  if (value is! String) throw FormatException('$fieldName格式错误');
  final parsed = DateTime.tryParse(value)?.toUtc();
  if (parsed == null) throw FormatException('$fieldName格式错误');
  return parsed;
}
