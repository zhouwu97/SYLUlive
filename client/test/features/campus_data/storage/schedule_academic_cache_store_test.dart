import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/storage/academic_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/account_cache_namespace.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';

import '../../../helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
    for (final userId in const <String>['app-user-a', 'app-user-b']) {
      AcademicPersistenceRegistry.set(userId, enabled: true);
    }
  });

  AesGcmAccountScopedSnapshotStore createVault(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
  }

  test('课表按 App 用户和来源账号隔离，密文不含课程明文', () async {
    final owner = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: createVault('app-user-a'),
    );
    await owner.writeSemesterStart(
      year: '2026',
      semester: 3,
      semesterStart: DateTime(2026, 9, 7),
    );
    await owner.writeCourses(
      year: '2026',
      semester: 3,
      courses: <Map<String, dynamic>>[
        _coursePayload(name: '离散数学', teacher: '张老师'),
      ],
    );

    final sameOwner = await owner.readTerm(year: '2026', semester: 3);
    expect(sameOwner?.courses.single['name'], '离散数学');
    expect(sameOwner?.semesterStart, DateTime.utc(2026, 9, 7));

    final changedSource = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240002',
      snapshotStore: createVault('app-user-a'),
    );
    expect(
      await changedSource.readTerm(year: '2026', semester: 3),
      isNull,
    );

    final otherUser = ScheduleCacheStore(
      appUserId: 'app-user-b',
      sourceAccountId: '20240001',
      snapshotStore: createVault('app-user-b'),
    );
    expect(await otherUser.readTerm(year: '2026', semester: 3), isNull);

    final storedText =
        files.values.values.map((bytes) => utf8.decode(bytes)).join('\n');
    expect(storedText, isNot(contains('离散数学')));
    expect(storedText, isNot(contains('20240001')));
  });

  test('课表不同学期并发写入后全部保留', () async {
    final snapshotStore = YieldingPersonalSnapshotStore(
      accountFingerprint: 'schedule-concurrent-account',
    );
    final first = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: snapshotStore,
    );
    final second = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: snapshotStore,
    );

    await Future.wait(<Future<void>>[
      first.writeCourses(
        year: '2025',
        semester: 3,
        courses: <Map<String, dynamic>>[_coursePayload(name: '高等数学')],
      ),
      second.writeCourses(
        year: '2026',
        semester: 12,
        courses: <Map<String, dynamic>>[_coursePayload(name: '大学英语')],
      ),
    ]);

    final snapshot = await first.readSnapshot();
    expect(snapshot?.terms.keys, containsAll(<String>['2025_3', '2026_12']));
    expect(snapshot?.terms['2025_3']?.courses.single['name'], '高等数学');
    expect(snapshot?.terms['2026_12']?.courses.single['name'], '大学英语');
  });

  test('未带来源账号的旧课表只清理并标记重新同步', () async {
    AppPreferencesStore.setMockInitialValues(<String, Object>{
      'course_cache_v5_app-user-a_2026_3': '[{"name":"旧课表"}]',
      'course_cache_v5_app-user-a_2026_3_ver': 5,
      'course_hidden_v5_app-user-a_2026_3': '[7]',
      'course_archives_v2_app-user-a_2026_3': '[]',
      'course_archive_data_v2_archive-old': '[{"name":"旧存档"}]',
      'active_archive_v2_app-user-a_2026_3': 'archive-old',
      'semester_start_v2_app-user-a_2026_3': '2026-09-07T00:00:00',
      'semester_start': '2026-09-07T00:00:00',
    });
    final store = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: createVault('app-user-a'),
    );

    await store.discardUnownedLegacy();

    final preferences = await AppPreferencesStore.getInstance();
    expect(
      preferences.containsKey('course_cache_v5_app-user-a_2026_3'),
      isFalse,
    );
    expect(
        preferences.containsKey('course_archive_data_v2_archive-old'), isFalse);
    expect(preferences.containsKey('semester_start'), isFalse);
    expect(
      preferences.getBool(
        AccountCacheNamespace.scheduleNeedsResync('app-user-a'),
      ),
      isTrue,
    );
    expect(await store.readSnapshot(), isNull);
  });

  test('成绩按学期合并并按来源账号失败关闭', () async {
    final owner = AcademicCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: createVault('app-user-a'),
    );
    await owner.writeGrades(
      year: '2025',
      semester: 3,
      grades: <Map<String, dynamic>>[_gradePayload('数据结构', '92')],
    );
    await owner.writeGrades(
      year: '2026',
      semester: 12,
      grades: <Map<String, dynamic>>[_gradePayload('操作系统', '88')],
    );
    await owner.writeAcademicSituation(
      data: <String, dynamic>{
        'success': true,
        'total_courses': 2,
        'courses': <Map<String, dynamic>>[],
      },
    );

    final snapshot = await owner.readSnapshot();
    expect(snapshot?.terms.keys, containsAll(<String>['2025_3', '2026_12']));
    expect(snapshot?.situation?.data['total_courses'], 2);

    final changedSource = AcademicCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240002',
      snapshotStore: createVault('app-user-a'),
    );
    expect(await changedSource.readSnapshot(), isNull);

    final storedText =
        files.values.values.map((bytes) => utf8.decode(bytes)).join('\n');
    expect(storedText, isNot(contains('数据结构')));
    expect(storedText, isNot(contains('20240001')));
  });

  test('成绩不同学期并发写入后全部保留', () async {
    final snapshotStore = YieldingPersonalSnapshotStore(
      accountFingerprint: 'academic-concurrent-account',
    );
    final first = AcademicCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: snapshotStore,
    );
    final second = AcademicCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: snapshotStore,
    );

    await Future.wait(<Future<void>>[
      first.writeGrades(
        year: '2025',
        semester: 3,
        grades: <Map<String, dynamic>>[_gradePayload('高等数学', '90')],
      ),
      second.writeGrades(
        year: '2026',
        semester: 12,
        grades: <Map<String, dynamic>>[_gradePayload('概率论', '91')],
      ),
    ]);

    final snapshot = await first.readSnapshot();
    expect(snapshot?.terms.keys, containsAll(<String>['2025_3', '2026_12']));
  });

  test('未知课表版本拒绝写入课程且保留原密文', () async {
    final vault = createVault('app-user-a');
    final store = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: vault,
    );
    await vault.write(
      type: PersonalDataType.schedule,
      schemaVersion: 99,
      sourceSystem: 'edu',
      sourceAccountId: '20240001',
      payload: <String, dynamic>{'terms': <String, dynamic>{}},
    );
    final fileKey =
        files.key(vault.accountFingerprint, PersonalDataType.schedule);
    final before = List<int>.from(files.values[fileKey]!);

    await expectLater(
      store.writeCourses(
        year: '2026',
        semester: 3,
        courses: <Map<String, dynamic>>[_coursePayload(name: '离散数学')],
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );

    expect(files.values[fileKey], orderedEquals(before));
  });

  test('未知课表版本拒绝写入学期起始日且保留原密文', () async {
    final vault = createVault('app-user-a');
    final store = ScheduleCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: vault,
    );
    await vault.write(
      type: PersonalDataType.schedule,
      schemaVersion: 99,
      sourceSystem: 'edu',
      sourceAccountId: '20240001',
      payload: <String, dynamic>{'terms': <String, dynamic>{}},
    );
    final fileKey =
        files.key(vault.accountFingerprint, PersonalDataType.schedule);
    final before = List<int>.from(files.values[fileKey]!);

    await expectLater(
      store.writeSemesterStart(
        year: '2026',
        semester: 3,
        semesterStart: DateTime.utc(2026, 9, 7),
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );

    expect(files.values[fileKey], orderedEquals(before));
  });

  test('未知成绩版本拒绝写入成绩且保留原密文', () async {
    final vault = createVault('app-user-a');
    final store = AcademicCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: vault,
    );
    await vault.write(
      type: PersonalDataType.academic,
      schemaVersion: 99,
      sourceSystem: 'edu',
      sourceAccountId: '20240001',
      payload: <String, dynamic>{
        'grade_terms': <String, dynamic>{},
        'academic_situation': null,
      },
    );
    final fileKey =
        files.key(vault.accountFingerprint, PersonalDataType.academic);
    final before = List<int>.from(files.values[fileKey]!);

    await expectLater(
      store.writeGrades(
        year: '2026',
        semester: 3,
        grades: <Map<String, dynamic>>[_gradePayload('离散数学', '90')],
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );

    expect(files.values[fileKey], orderedEquals(before));
  });

  test('未知成绩版本拒绝写入学业情况且保留原密文', () async {
    final vault = createVault('app-user-a');
    final store = AcademicCacheStore(
      appUserId: 'app-user-a',
      sourceAccountId: '20240001',
      snapshotStore: vault,
    );
    await vault.write(
      type: PersonalDataType.academic,
      schemaVersion: 99,
      sourceSystem: 'edu',
      sourceAccountId: '20240001',
      payload: <String, dynamic>{
        'grade_terms': <String, dynamic>{},
        'academic_situation': null,
      },
    );
    final fileKey =
        files.key(vault.accountFingerprint, PersonalDataType.academic);
    final before = List<int>.from(files.values[fileKey]!);

    await expectLater(
      store.writeAcademicSituation(
        data: <String, dynamic>{'success': true, 'total_courses': 1},
      ),
      throwsA(isA<PersonalSnapshotStoreException>()),
    );

    expect(files.values[fileKey], orderedEquals(before));
  });
}

Map<String, dynamic> _coursePayload({
  required String name,
  String? teacher,
}) {
  return <String, dynamic>{
    'id': 1,
    'course_code': 'CODE-1',
    'name': name,
    'teacher': teacher,
    'location': 'A101',
    'color': '#6366F1',
    'weekday': 1,
    'start_section': 1,
    'end_section': 2,
    'weeks': <int>[1, 2, 3],
    'note': null,
  };
}

Map<String, dynamic> _gradePayload(String name, String grade) {
  return <String, dynamic>{
    'name': name,
    'grade': grade,
    'credits': 3,
    'gpa': 4.0,
    'is_degree': true,
  };
}
