import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/models/schedule/schedule_override.dart';
import 'package:shenliyuan/repositories/schedule_override_repository.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

import 'helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class _TemporarilyUnavailableSecureStore
    extends MemoryPersonalSnapshotSecureStore {
  bool unavailable = false;
  int remainingFailures = 0;

  @override
  Future<String?> read(String key) async {
    if (unavailable) throw StateError('测试：后台恢复期间密钥暂不可读');
    if (remainingFailures > 0) {
      remainingFailures--;
      throw StateError('测试：首次密钥读取尚未就绪');
    }
    return super.read(key);
  }
}

class _PausedSnapshotFiles extends MemoryPersonalSnapshotFileBackend {
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;

  @override
  Future<void> write({
    required String accountHash,
    required PersonalDataType type,
    required Uint8List bytes,
  }) async {
    final gate = releaseWrite;
    if (gate != null) {
      releaseWrite = null;
      writeStarted?.complete();
      await gate.future;
    }
    await super.write(accountHash: accountHash, type: type, bytes: bytes);
  }
}

class _PausedOverrideRepository extends ScheduleOverrideRepository {
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;

  @override
  Future<bool> upsertOverride({
    required ScheduleOverride override,
    String? accountId,
  }) async {
    final gate = releaseWrite;
    if (gate != null) {
      releaseWrite = null;
      writeStarted?.complete();
      await gate.future;
    }
    return super.upsertOverride(override: override, accountId: accountId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    // 这些用例测试已连接账号的持久化，需满足新增的身份连接许可。
    final preferences = await AppPreferencesStore.getInstance();
    for (final userId in ['1001', '2002']) {
      for (final studentId in [
        '2403130233',
        '2403130234',
        '2606610216',
        'G-001',
        'G-PAIR',
        'G-STRICT',
        'G-LEGACY'
      ]) {
        final identity = AcademicIdentityKey(
            appUserId: userId,
            providerId: AcademicProviderId.syluUndergraduate,
            studentId: studentId);
        await preferences.setBool(
            'academic_lifecycle_${identity.storageId}_connected', true);
      }
    }
    AcademicPersistenceRegistry.set('1001', enabled: true);
    AcademicPersistenceRegistry.set('2002', enabled: true);
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
  });

  tearDown(() {
    AcademicPersistenceRegistry.clear('1001');
    AcademicPersistenceRegistry.clear('2002');
  });

  AccountScopedSnapshotStore createSnapshotStore(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
  }

  CourseScheduleProvider createProvider([Dio? dio]) {
    return CourseScheduleProvider(dio, createSnapshotStore);
  }

  test('后台重建时密钥暂不可读不应判为空课表，重试恢复原学期和课程', () async {
    final flakySecureStore = _TemporarilyUnavailableSecureStore();
    secureStore = flakySecureStore;
    final seed = createProvider()..syncSessionContext('1001', '2403130233');
    const term = CourseTerm(
      id: '2025_12',
      year: '2025',
      semester: 12,
      title: '2025-2026 第二学期',
      maxWeek: 20,
    );
    await seed.applyFetchedCoursesForTerm(term: term, rawCourses: [
      {
        'name': '线性代数',
        'time': 1,
        'end_time': 2,
        'week_day': 2,
        'weeks': [1, 2, 3]
      },
    ]);
    seed.dispose();
    final savedFiles = Map.of(files.values);
    expect(savedFiles, isNotEmpty);
    flakySecureStore.unavailable = true;
    final restored = createProvider()..syncSessionContext('1001', '2403130233');
    addTearDown(restored.dispose);
    final failed = Completer<void>();
    restored.addListener(() {
      if (restored.sessionPhase == ScheduleSessionPhase.restoreFailed &&
          !failed.isCompleted) {
        failed.complete();
      }
    });
    await failed.future.timeout(const Duration(seconds: 2));
    expect(restored.isSessionReady, isFalse, reason: '本地读取失败不能向页面宣告空课表已恢复完成');
    expect(restored.errorMessage, isNotNull);
    expect(files.values, savedFiles);
    flakySecureStore.unavailable = false;
    await restored.retryLocalRestore();
    expect(restored.isSessionReady, isTrue);
    expect(restored.currentTerm.id, term.id);
    expect(restored.courses.single.name, '线性代数');
    expect(restored.errorMessage, isNull);
    // 第二次模拟进程重建：只有第一次读取失败时，应自行恢复，无需重新拉取。
    flakySecureStore.remainingFailures = 1;
    final retried = createProvider()..syncSessionContext('1001', '2403130233');
    addTearDown(retried.dispose);
    final ready = Completer<void>();
    retried.addListener(() {
      if (retried.isSessionReady && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(const Duration(seconds: 2));
    expect(retried.currentTerm.id, term.id);
    expect(retried.courses.single.name, '线性代数');
    expect(files.values, savedFiles);
  });

  test('onlyCache load ends immediately when no course cache exists', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');

    await provider.loadCourses(onlyCache: true);

    expect(provider.isLoading, isFalse);
    expect(provider.courses, isEmpty);
    expect(provider.gridData, isEmpty);
  });

  test('来源账号延迟恢复后自动进入 ready 并读取对应会话缓存', () async {
    final seed = createProvider()..syncSessionContext('1001', '2403130233');
    await seed.applyFetchedCourses([
      {
        'name': '线性代数',
        'time': 1,
        'end_time': 2,
        'week_day': 2,
        'weeks': [1, 2, 3],
      },
    ]);

    final provider = createProvider()..syncSessionContext('1001', '');
    expect(provider.sessionPhase, ScheduleSessionPhase.resolvingIdentity);
    expect(provider.isSessionReady, isFalse);

    final generationBeforeSource = provider.contextGeneration;
    provider.syncSessionContext('1001', '2403130233');
    expect(provider.contextGeneration, greaterThan(generationBeforeSource));
    expect(provider.sessionKey, '1001::2403130233');

    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(provider.isSessionReady, isTrue);
    expect(provider.sessionPhase, ScheduleSessionPhase.ready);
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.name, '线性代数');
  });

  test(
      'fetched courses are available from cache for the same user and semester',
      () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');

    await provider.applyFetchedCourses([
      {
        'name': '高等数学',
        'teacher': '王老师',
        'location': 'A101',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2, 3],
      },
    ]);

    final reloaded = createProvider()..syncSessionContext('1001', '2403130233');
    final loaded = await reloaded.loadCachedCoursesIfAvailable();

    expect(loaded, isTrue);
    expect(reloaded.isLoading, isFalse);
    expect(reloaded.courses, hasLength(1));
    expect(reloaded.courses.single.name, '高等数学');
  });

  test('研究生节次元数据写入并从课表缓存恢复', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-001');

    await provider.applyFetchedCourses([
      {
        'name': '研究生专题课',
        'teacher': '王老师',
        'location': '研究生楼 A301',
        'weekday': 1,
        'start_section': 3,
        'end_section': 3,
        'period_order': 2,
        'period_label': '上午3',
        'weeks': [1, 2, 3],
      },
    ]);

    expect(provider.courses.single.startSection, 3);
    expect(provider.courses.single.endSection, 3);
    expect(provider.courses.single.periodOrder, 2);
    expect(provider.courses.single.periodLabel, '上午3');

    final reloaded = createProvider()..syncSessionContext('1001', 'G-001');
    expect(await reloaded.loadCachedCoursesIfAvailable(), isTrue);
    expect(reloaded.courses.single.startSection, 3);
    expect(reloaded.courses.single.periodOrder, 2);
    expect(reloaded.courses.single.periodLabel, '上午3');

    final snapshot = await ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: 'G-001',
      snapshotStore: createSnapshotStore('1001'),
    ).readTerm(
      year: provider.selectedYear,
      semester: provider.selectedSemester,
    );
    expect(snapshot?.courses.single['period_order'], 2);
    expect(snapshot?.courses.single['period_label'], '上午3');
  });

  test('研究生固定相邻节次归并并保留逐行标签', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-PAIR');

    await provider.applyFetchedCourses([
      for (var index = 0; index < 4; index++)
        <String, dynamic>{
          'course_code': 'G-101',
          'name': '新时代中国特色社会主义理论与实践研究4班',
          'teacher': '张慧雪',
          'location': '综合楼 A224',
          'weekday': 1,
          'start_section': index + 1,
          'end_section': index + 1,
          'period_order': index,
          'period_label': '上午${index + 1}',
          'weeks': <int>[3, 4, 5, 6],
        },
    ]);

    expect(provider.courses, hasLength(2));
    expect(
      provider.courses.map((course) => course.periodLabel),
      <String>['上午1-2', '上午3-4'],
    );
    expect(
      provider.courses.map((course) => course.startSection),
      <int>[1, 3],
    );
    expect(
      provider.courses.map((course) => course.endSection),
      <int>[2, 4],
    );
    expect(
      provider.courses.last.periodLabels,
      <String>['上午3', '上午4'],
    );

    final reloaded = createProvider()..syncSessionContext('1001', 'G-PAIR');
    expect(await reloaded.loadCachedCoursesIfAvailable(), isTrue);
    expect(reloaded.courses, hasLength(2));
    expect(
      reloaded.courses.last.periodLabels,
      <String>['上午3', '上午4'],
    );

    final snapshot = await ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: 'G-PAIR',
      snapshotStore: createSnapshotStore('1001'),
    ).readTerm(
      year: provider.selectedYear,
      semester: provider.selectedSemester,
    );
    expect(
      snapshot?.courses.last['period_labels'],
      <String>['上午3', '上午4'],
    );
  });

  test('研究生相邻记录仅在固定配对且周次完全相同时归并', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-STRICT');

    await provider.applyFetchedCourses([
      <String, dynamic>{
        'name': '周次不同课程',
        'teacher': '王老师',
        'location': 'A101',
        'weekday': 1,
        'start_section': 1,
        'end_section': 1,
        'period_order': 0,
        'period_label': '上午1',
        'weeks': <int>[1, 2],
      },
      <String, dynamic>{
        'name': '周次不同课程',
        'teacher': '王老师',
        'location': 'A101',
        'weekday': 1,
        'start_section': 2,
        'end_section': 2,
        'period_order': 1,
        'period_label': '上午2',
        'weeks': <int>[1, 2, 3],
      },
      <String, dynamic>{
        'name': '跨配对课程',
        'teacher': '李老师',
        'location': 'A102',
        'weekday': 2,
        'start_section': 3,
        'end_section': 3,
        'period_order': 2,
        'period_label': '上午2',
        'weeks': <int>[1, 2],
      },
      <String, dynamic>{
        'name': '跨配对课程',
        'teacher': '李老师',
        'location': 'A102',
        'weekday': 2,
        'start_section': 4,
        'end_section': 4,
        'period_order': 3,
        'period_label': '上午3',
        'weeks': <int>[1, 2],
      },
    ]);

    expect(provider.courses, hasLength(4));
    expect(provider.courses.every((course) => course.span == 1), isTrue);
  });

  test('旧缓存缺少来源快照时保留展示并提示重新同步', () async {
    final term = CourseTerm.inferCurrentTerm();
    final store = ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: 'G-LEGACY',
      snapshotStore: createSnapshotStore('1001'),
    );
    await store.writeCourses(
      year: term.year,
      semester: term.semester,
      courses: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 1,
          'name': '研究生专题课',
          'teacher': '王老师',
          'location': 'A101',
          'weekday': 1,
          'start_section': 3,
          'end_section': 3,
          'period_order': 2,
          'period_label': '上午3',
          'weeks': <int>[1, 2],
        },
        <String, dynamic>{
          'id': 2,
          'name': '研究生专题课',
          'teacher': '王老师',
          'location': 'A101',
          'weekday': 1,
          'start_section': 4,
          'end_section': 4,
          'period_order': 3,
          'period_label': '上午4',
          'weeks': <int>[1, 2],
        },
      ],
    );
    final provider = createProvider()..syncSessionContext('1001', 'G-LEGACY');

    expect(await provider.loadCachedCoursesIfAvailable(), isTrue);
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.span, 2);
    expect(provider.courses.single.periodLabels, <String>['上午3', '上午4']);
    expect(provider.errorMessage, contains('重新同步教务'));

    final preserved = await store.readTerm(
      year: term.year,
      semester: term.semester,
    );
    expect(preserved?.sourceSnapshotPresent, isFalse);
    expect(preserved?.courses, hasLength(2));

    await expectLater(
      provider.addCustomCourse(
        name: '不可直接追加',
        weekday: 2,
        startSection: 1,
        endSection: 1,
        startWeek: 1,
        endWeek: 1,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('两条同名自定义课程保持独立身份并可单独删除', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-001');
    addTearDown(provider.dispose);

    await provider.addCustomCourse(
      name: '自习',
      weekday: 2,
      startSection: 1,
      endSection: 2,
      startWeek: 1,
      endWeek: 4,
    );
    await provider.addCustomCourse(
      name: '自习',
      weekday: 4,
      startSection: 3,
      endSection: 4,
      startWeek: 1,
      endWeek: 4,
    );

    expect(provider.courses, hasLength(2));
    expect(provider.courses.map((course) => course.id).toSet(), hasLength(2));
    expect(
      provider.courses.map((course) => course.courseKey).toSet(),
      hasLength(2),
    );

    final tuesdayId =
        provider.courses.singleWhere((course) => course.weekday == 2).id;
    await provider.removeCustomCourse(tuesdayId);
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.weekday, 4);

    final restored = createProvider()..syncSessionContext('1001', 'G-001');
    addTearDown(restored.dispose);
    expect(await restored.loadCachedCoursesIfAvailable(), isTrue);
    expect(restored.courses, hasLength(1));
    expect(restored.courses.single.weekday, 4);
  });

  test('载入存档后重算和冷启动都不回到载入前课表', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-PAIR');
    addTearDown(provider.dispose);

    await provider.applyFetchedCourses([
      {
        'name': '存档课程',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2]
      },
    ]);
    final archive = await provider.saveCurrentAsArchive('存档 B');

    await provider.applyFetchedCourses([
      {
        'name': '载入前课程',
        'time': 3,
        'end_time': 4,
        'week_day': 3,
        'weeks': [1, 2]
      },
    ]);
    await provider.loadArchive(archive.id);
    await provider.addCustomCourse(
      name: '存档后自习',
      weekday: 5,
      startSection: 5,
      endSection: 6,
      startWeek: 1,
      endWeek: 2,
    );

    expect(
      provider.courses.map((course) => course.name),
      containsAll(['存档课程', '存档后自习']),
    );
    expect(
      provider.courses.map((course) => course.name),
      isNot(contains('载入前课程')),
    );

    final restored = createProvider()..syncSessionContext('1001', 'G-PAIR');
    addTearDown(restored.dispose);
    expect(await restored.loadCachedCoursesIfAvailable(), isTrue);
    expect(
      restored.courses.map((course) => course.name),
      containsAll(['存档课程', '存档后自习']),
    );
    expect(
      restored.courses.map((course) => course.name),
      isNot(contains('载入前课程')),
    );
  });

  test('载入存档回滚无法完整落盘时明确提示并保留原内存课表', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-PAIR');
    addTearDown(provider.dispose);
    await provider.applyFetchedCourses([
      {
        'name': '存档课程',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2]
      },
    ]);
    final archive = await provider.saveCurrentAsArchive('存档回滚测试');
    await provider.applyFetchedCourses([
      {
        'name': '原课表课程',
        'time': 3,
        'end_time': 4,
        'week_day': 3,
        'weeks': [1, 2]
      },
    ]);

    files.failWrites = true;
    await expectLater(
      provider.loadArchive(archive.id),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('原课表恢复未完成'),
      )),
    );
    expect(provider.courses.single.name, '原课表课程');
    files.failWrites = false;

    final restored = createProvider()..syncSessionContext('1001', 'G-PAIR');
    addTearDown(restored.dispose);
    expect(await restored.loadCachedCoursesIfAvailable(), isTrue);
    expect(restored.courses.single.name, '原课表课程');
  });

  test('隐藏课程身份经过来源快照恢复和再次同步仍保持稳定', () async {
    final rawCourses = <Map<String, dynamic>>[
      {
        'course_code': 'CS101',
        'name': '数据结构',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2]
      },
      {
        'course_code': 'MA101',
        'name': '高等数学',
        'time': 3,
        'end_time': 4,
        'week_day': 2,
        'weeks': [1, 2]
      },
    ];
    final provider = createProvider()..syncSessionContext('1001', 'G-STRICT');
    addTearDown(provider.dispose);
    await provider.applyFetchedCourses(rawCourses);
    final hiddenId =
        provider.courses.singleWhere((course) => course.name == '数据结构').id;
    await provider.removeCustomCourse(hiddenId);

    final restored = createProvider()..syncSessionContext('1001', 'G-STRICT');
    addTearDown(restored.dispose);
    expect(await restored.loadCachedCoursesIfAvailable(), isTrue);
    expect(restored.courses.map((course) => course.name), ['高等数学']);

    await restored.applyFetchedCourses(rawCourses, resetHidden: false);
    expect(restored.courses.map((course) => course.name), ['高等数学']);
  });

  test('自定义课程写入失败时抛出错误且回滚内存课程状态', () async {
    final provider = createProvider()..syncSessionContext('1001', 'G-001');
    addTearDown(provider.dispose);
    files.failWrites = true;

    await expectLater(
      provider.addCustomCourse(
        name: '待保存课程',
        weekday: 2,
        startSection: 1,
        endSection: 2,
        startWeek: 1,
        endWeek: 2,
      ),
      throwsA(isA<StateError>()),
    );
    expect(provider.courses, isEmpty);
  });

  test('旧账号课程写入完成后不得回滚或覆盖新账号课表', () async {
    final pausedFiles = _PausedSnapshotFiles();
    files = pausedFiles;
    final seedB = createProvider()..syncSessionContext('2002', '2403130234');
    await seedB.applyFetchedCourses([
      {
        'name': '新账号课程',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1]
      }
    ]);
    seedB.dispose();

    for (final mutation in ['add', 'edit', 'remove', 'hide']) {
      final seedA = createProvider()..syncSessionContext('1001', '2403130233');
      await seedA.applyFetchedCourses([
        {
          'name': '旧账号课程',
          'time': 3,
          'end_time': 4,
          'week_day': 2,
          'weeks': [1]
        }
      ]);
      if (mutation == 'edit' || mutation == 'remove') {
        await seedA.addCustomCourse(
          name: '旧账号自定义课',
          weekday: 3,
          startSection: 1,
          endSection: 2,
          startWeek: 1,
          endWeek: 2,
        );
      }
      final manualId = seedA.courses.where((c) => c.id < 0).firstOrNull?.id;
      final serverId = seedA.courses.singleWhere((c) => c.id > 0).id;
      seedA.dispose();

      final provider = createProvider()
        ..syncSessionContext('1001', '2403130233');
      addTearDown(provider.dispose);
      expect(await provider.loadCachedCoursesIfAvailable(), isTrue);
      pausedFiles.writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      pausedFiles.releaseWrite = releaseWrite;
      final pending = switch (mutation) {
        'add' => provider.addCustomCourse(
            name: '未完成新增',
            weekday: 4,
            startSection: 1,
            endSection: 2,
            startWeek: 1,
            endWeek: 2,
          ),
        'edit' => provider.editCustomCourse(
            id: manualId!,
            name: '未完成编辑',
            weekday: 4,
            startSection: 1,
            endSection: 2,
            startWeek: 1,
            endWeek: 2,
          ),
        'remove' => provider.removeCustomCourse(manualId!),
        _ => provider.removeCustomCourse(serverId),
      };
      await pausedFiles.writeStarted!.future
          .timeout(const Duration(seconds: 2));
      provider.syncSessionContext('2002', '2403130234');
      expect(await provider.loadCachedCoursesIfAvailable(), isTrue);
      releaseWrite.complete();
      await expectLater(pending, throwsA(isA<StateError>()));
      expect(provider.courses.map((c) => c.name), ['新账号课程']);
      expect(provider.manualCourses, isEmpty);
      expect(provider.getCoursesAt(1, 1).single.name, '新账号课程');
      final bStore = ScheduleCacheStore(
        appUserId: '2002',
        sourceAccountId: '2403130234',
        snapshotStore: createSnapshotStore('2002'),
      );
      final bSnapshot = await bStore.readTerm(
        year: provider.currentTerm.year,
        semester: provider.currentTerm.semester,
      );
      expect(bSnapshot?.courses.single['name'], '新账号课程');
      final preferences = await AppPreferencesStore.getInstance();
      for (var i = 0; i < 20; i++) {
        if (preferences.getString('widget_course_data')?.contains('新账号课程') ==
            true) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final widgetPayload = preferences.getString('widget_course_data');
      expect(widgetPayload, contains('新账号课程'));
      expect(widgetPayload, isNot(contains('旧账号课程')));
    }
  });

  test('旧账号调课规则保存完成后不得加载到新账号课表', () async {
    final repository = _PausedOverrideRepository();
    final seedB = createProvider()..syncSessionContext('2002', '2403130234');
    await seedB.applyFetchedCourses([
      {
        'name': '新账号课程',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1]
      }
    ]);
    seedB.dispose();

    final provider = CourseScheduleProvider(
      null,
      createSnapshotStore,
      null,
      null,
      repository,
    )..syncSessionContext('1001', '2403130233');
    addTearDown(provider.dispose);
    await provider.applyFetchedCourses([
      {
        'name': '旧账号课程',
        'time': 3,
        'end_time': 4,
        'week_day': 2,
        'weeks': [1]
      }
    ]);
    final oldCourse = provider.courses.single;
    repository.writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    repository.releaseWrite = releaseWrite;
    final pending = provider.createChangeRoomOverride(
      courseKey: oldCourse.courseKey!,
      meetingKey: oldCourse.meetingKey!,
      affectedWeeks: {1},
      toRoom: '旧账号新教室',
      sourceSnapshotHash:
          provider.baseSchedule.single.meetings.single.computeSnapshotHash(),
    );
    await repository.writeStarted!.future.timeout(const Duration(seconds: 2));
    provider.syncSessionContext('2002', '2403130234');
    expect(await provider.loadCachedCoursesIfAvailable(), isTrue);
    releaseWrite.complete();
    await expectLater(pending, throwsA(isA<StateError>()));
    expect(provider.courses.map((c) => c.name), ['新账号课程']);
    expect(provider.overrides, isEmpty);
    expect(
        await repository.loadOverrides(
          semesterId: provider.currentTerm.id,
          accountId: '2403130234',
        ),
        isEmpty);
  });

  test('来源学号变化后不读取旧课表缓存', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');
    await provider.applyFetchedCourses(<Map<String, dynamic>>[
      <String, dynamic>{
        'name': '数据结构',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': <int>[1, 2],
      },
    ]);

    final changedSource = createProvider()
      ..syncSessionContext('1001', '2403130234');
    final loaded = await changedSource.loadCachedCoursesIfAvailable();

    expect(loaded, isFalse);
    expect(changedSource.courses, isEmpty);
  });

  test('延迟课表响应在换号后不会写入新账号或恢复旧界面', () async {
    final courseStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    final repository = _FakeCourseRepository(
      courseStarted: courseStarted,
      courseGate: releaseResponse,
      courses: CourseFetchResult(
        source: CourseSource.mobile,
        courses: [
          const RawCourse(
            name: '旧账号课程',
            teacher: '测试老师',
            location: 'A101',
            section: '1-2节',
            weekDay: '1',
            weekExpression: '1周',
          ),
        ],
      ),
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('1001');
    await controller.login(studentId: '2403130233', password: 'secret');
    final provider = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      controller,
    )..syncSessionContext('1001', '2403130233');

    final pending = provider.loadCourses(forceRefresh: true);
    await courseStarted.future;
    provider.syncSessionContext('2002', '2403130234');
    releaseResponse.complete();
    await pending;

    expect(provider.courses, isEmpty);
    final oldStore = ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: '2403130233',
      snapshotStore: createSnapshotStore('1001'),
    );
    final newStore = ScheduleCacheStore(
      appUserId: '2002',
      sourceAccountId: '2403130234',
      snapshotStore: createSnapshotStore('2002'),
    );
    expect(await oldStore.readTerm(year: '2025', semester: 12), isNull);
    expect(await newStore.readTerm(year: '2025', semester: 12), isNull);
    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    provider.dispose();
    controller.dispose();
  });

  test('课程获取成功但保险箱写入失败时明确提示未持久化', () async {
    final repository = _FakeCourseRepository(
      courses: CourseFetchResult(
        source: CourseSource.mobile,
        courses: [
          const RawCourse(
            name: '数据结构',
            teacher: '测试老师',
            location: 'A101',
            section: '1-2节',
            weekDay: '1',
            weekExpression: '1-2周',
          ),
        ],
      ),
    );
    files.failWrites = true;
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('1001');
    await controller.login(studentId: '2403130233', password: 'secret');
    final provider = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      controller,
    )..syncSessionContext('1001', '2403130233');

    await provider.loadCourses(forceRefresh: true);

    expect(provider.courses.single.name, '数据结构');
    expect(provider.errorMessage, '课程已获取，但未能安全保存，请稍后重试');
    expect(provider.isLoading, isFalse);
    provider.dispose();
    controller.dispose();
  });

  test('研究生稀疏节次和超过本科范围的行数保留 Provider 行序', () async {
    final provider = createProvider()..syncSessionContext('1001', '2606610216');

    await provider.applyFetchedCourses([
      {
        'name': '研究生专题课',
        'teacher': '测试老师',
        'location': 'A101',
        'weekday': 1,
        'start_section': 3,
        'end_section': 3,
        'period_order': 2,
        'period_label': '上午3',
        'weeks': [1],
      },
      {
        'name': '研究生研讨课',
        'teacher': '测试老师',
        'location': 'A102',
        'weekday': 2,
        'start_section': 14,
        'end_section': 14,
        'period_order': 13,
        'period_label': '下午8',
        'weeks': [1],
      },
    ]);

    expect(provider.usesProviderPeriodLayout, isTrue);
    expect(provider.periodSlotCount, 14);
    expect(provider.courses.first.periodOrder, 2);
    expect(provider.courses.last.periodLabel, '下午8');
  });

  test('已知研究生 Provider 即使没有课程也不回退本科 12 节布局', () {
    final controller = AcademicSessionController(
      repository: _FakeCourseRepository(
        courses: CourseFetchResult(
          source: CourseSource.mobile,
          courses: [],
        ),
      ),
      identity: const AcademicIdentityKey(
        appUserId: '1001',
        providerId: AcademicProviderId.syluGraduate,
        studentId: '2606610216',
      ),
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final provider = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      null,
      controller,
    );

    expect(provider.usesProviderPeriodLayout, isTrue);
    expect(provider.periodSlotCount, 1);

    provider.dispose();
    controller.dispose();
  });

  test('研究生选中学校学期在新 Provider 冷启动后恢复并命中同一缓存', () async {
    final repository = _FakeCourseRepository(
      courses: CourseFetchResult(
        source: CourseSource.mobile,
        courses: const <RawCourse>[],
      ),
    );
    final controller = AcademicSessionController(
      repository: repository,
      identity: const AcademicIdentityKey(
        appUserId: '1001',
        providerId: AcademicProviderId.syluGraduate,
        studentId: '2606610216',
      ),
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final term = const CourseTerm(
      id: 'provider_graduate_term_2026_1',
      year: 'provider_graduate_term_2026',
      semester: 1,
      title: '2026-2027 秋季学期',
      providerTermId: 'graduate-term-2026-1',
      maxWeek: 20,
    );
    final first = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      controller,
    )..syncSessionContext('1001', '2606610216');

    expect(
      await first.applyFetchedCoursesForTerm(
        term: term,
        rawCourses: [
          {
            'name': '研究生专题课',
            'teacher': '测试老师',
            'location': 'A101',
            'weekday': 1,
            'start_section': 3,
            'end_section': 3,
            'period_order': 2,
            'period_label': '上午3',
            'weeks': [1],
          },
        ],
      ),
      1,
    );

    final second = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      controller,
    )..syncSessionContext('1001', '2606610216');
    for (var i = 0; i < 20 && !second.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(second.isSessionReady, isTrue);
    expect(second.currentTerm.id, term.id);
    expect(second.currentTerm.providerTermId, term.providerTermId);
    expect(second.courses, hasLength(1));
    expect(second.courses.single.periodOrder, 2);
    expect(second.courses.single.periodLabel, '上午3');

    final otherController = AcademicSessionController(
      repository: repository,
      identity: const AcademicIdentityKey(
        appUserId: '2002',
        providerId: AcademicProviderId.syluGraduate,
        studentId: '2606610216',
      ),
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final other = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      otherController,
    )..syncSessionContext('2002', '2606610216');
    for (var i = 0; i < 20 && !other.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(other.isSessionReady, isTrue);
    expect(other.currentTerm.providerTermId, isNull);
    expect(other.courses, isEmpty);

    first.dispose();
    second.dispose();
    other.dispose();
    controller.dispose();
    otherController.dispose();
  });

  test('P1: 切换到无缓存学期后添加自定义课程，保存和恢复均不串入旧学期课程', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');
    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(provider.isSessionReady, isTrue);

    const termA = CourseTerm(
      id: '2025_1',
      year: '2025',
      semester: 1,
      title: '2025-2026 第一学期',
      maxWeek: 20,
    );
    const termB = CourseTerm(
      id: '2025_2',
      year: '2025',
      semester: 2,
      title: '2025-2026 第二学期',
      maxWeek: 20,
    );

    // 1. 学期 A 加载真实教务课程
    await provider.applyFetchedCoursesForTerm(
      term: termA,
      rawCourses: [
        {
          'name': '学期A高等数学',
          'time': 1,
          'end_time': 2,
          'week_day': 1,
          'weeks': [1, 2, 3],
          'location': '教一101',
          'teacher': '张老师',
        },
      ],
    );
    expect(provider.currentTerm.id, termA.id);
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.name, '学期A高等数学');
    expect(provider.baseSchedule, hasLength(1));

    // 2. 切换到没有缓存的学期 B
    final switched = await provider.switchTerm(termB);
    expect(switched, isFalse);
    expect(provider.currentTerm.id, termB.id);
    expect(provider.courses, isEmpty);
    expect(provider.baseSchedule, isEmpty);
    expect(provider.manualCourses, isEmpty);

    // 3. 在学期 B 添加一门自定义课程
    await provider.addCustomCourse(
      name: '学期B自定义课程',
      weekday: 3,
      startSection: 3,
      endSection: 4,
      startWeek: 1,
      endWeek: 4,
      location: '教二202',
      teacher: '李老师',
    );
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.name, '学期B自定义课程');

    // 4. 验证存储中学期 B 的快照：baseCourses 必须为空，绝不含学期 A 的课程
    final cacheStore = ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: '2403130233',
      snapshotStore: createSnapshotStore('1001'),
    );
    final snapshotB = await cacheStore.readTerm(
      year: termB.year,
      semester: termB.semester,
    );
    expect(snapshotB, isNotNull);
    expect(snapshotB!.baseCourses, isEmpty,
        reason: '学期 B 的底层教务课表快照绝不能串入学期 A 的教务课程');
    expect(snapshotB.manualCourses, hasLength(1));
    expect(snapshotB.manualCourses.single['name'], '学期B自定义课程');

    provider.dispose();

    // 5. 新建 Provider 恢复学期 B
    final restored = createProvider()..syncSessionContext('1001', '2403130233');
    for (var i = 0; i < 20 && !restored.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(restored.isSessionReady, isTrue);
    await restored.switchTerm(termB);

    expect(restored.currentTerm.id, termB.id);
    expect(restored.courses, hasLength(1));
    expect(restored.courses.single.name, '学期B自定义课程');
    expect(restored.baseSchedule, isEmpty);
    expect(restored.courses.any((c) => c.name.contains('学期A')), isFalse);

    restored.dispose();
  });

  test('切换已拉取学期恢复课程与开学周，重新拉取不清除开学周', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');
    addTearDown(provider.dispose);
    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(provider.isSessionReady, isTrue);

    final termA = CourseTerm(
      id: '2025_1',
      year: '2025',
      semester: 1,
      title: '2025-2026 第一学期',
      maxWeek: 20,
    );
    final termB = CourseTerm(
      id: '2025_2',
      year: '2025',
      semester: 2,
      title: '2025-2026 第二学期',
      maxWeek: 20,
    );
    final startA = DateTime(2025, 9, 1);
    final startB = DateTime(2026, 3, 2);

    await provider.applyFetchedCoursesForTerm(
      term: termA,
      rawCourses: [
        {
          'name': '学期 A 课程',
          'time': 1,
          'end_time': 2,
          'week_day': 1,
          'weeks': [1, 2],
        },
      ],
    );
    await provider.setSemesterStart(startA);

    await provider.applyFetchedCoursesForTerm(
      term: termB,
      rawCourses: [
        {
          'name': '学期 B 课程',
          'time': 3,
          'end_time': 4,
          'week_day': 2,
          'weeks': [1, 2],
        },
      ],
    );
    await provider.setSemesterStart(startB);

    expect(await provider.switchTerm(termA), isTrue);
    expect(provider.courses.single.name, '学期 A 课程');
    expect(provider.semesterStart, startA);

    // 对已有缓存学期再次拉取时，仍应沿用其已保存的开学周。
    await provider.applyFetchedCoursesForTerm(
      term: termA,
      rawCourses: [
        {
          'name': '学期 A 更新课程',
          'time': 1,
          'end_time': 2,
          'week_day': 3,
          'weeks': [1, 2],
        },
      ],
    );
    expect(provider.courses.single.name, '学期 A 更新课程');
    expect(provider.semesterStart, startA);

    expect(await provider.switchTerm(termB), isTrue);
    expect(provider.courses.single.name, '学期 B 课程');
    expect(provider.semesterStart, startB);
  });

  test('P2: 注入第二阶段快照存储失败，自定义课程回滚内存，调课规则保留可恢复状态', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');
    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(provider.isSessionReady, isTrue);

    const term = CourseTerm(
      id: '2025_1',
      year: '2025',
      semester: 1,
      title: '2025-2026 第一学期',
      maxWeek: 20,
    );
    await provider.applyFetchedCoursesForTerm(
      term: term,
      rawCourses: [
        {
          'name': '大学物理',
          'time': 1,
          'end_time': 2,
          'week_day': 1,
          'weeks': [1, 2, 3],
          'location': '物理楼101',
          'teacher': '赵老师',
        },
      ],
    );
    expect(provider.courses, hasLength(1));
    final initialMeetingKey = provider.courses.single.meetingKey!;
    final initialCourseKey = provider.courses.single.courseKey!;
    final meeting = provider.baseSchedule.first.meetings.first;
    final hash = meeting.computeSnapshotHash();

    // Case 1: 自定义课程保存失败时，回滚内存状态
    files.failWrites = true;
    await expectLater(
      () => provider.addCustomCourse(
        name: '失败的自定义课',
        weekday: 2,
        startSection: 1,
        endSection: 2,
        startWeek: 1,
        endWeek: 2,
      ),
      throwsA(isA<StateError>()),
    );
    // 验证内存已被回滚，没有残留
    expect(provider.courses, hasLength(1));
    expect(provider.courses.any((c) => c.name == '失败的自定义课'), isFalse);
    expect(provider.manualCourses, isEmpty);

    // Case 2: 调课规则写入成功（规则库成功），但第二阶段展示快照失败
    // 规则是事实来源，整次调课不应整体崩溃报错，且内存中应用新规则、规则库保留落盘
    final override = await provider.createRescheduleOverride(
      courseKey: initialCourseKey,
      meetingKey: initialMeetingKey,
      affectedWeeks: {1, 2},
      toWeekday: 5,
      toStartSection: 3,
      toEndSection: 4,
      toRoom: '新教室505',
      sourceSnapshotHash: hash,
    );
    expect(override, isNotNull);
    expect(provider.overrides, hasLength(1));
    expect(
      provider.courses.any((c) => c.weekday == 5 && c.startSection == 3),
      isTrue,
    );

    // 恢复正常写入
    files.failWrites = false;

    // 重新从规则库加载，确保规则确实成功持久化
    final overrideRepo = ScheduleOverrideRepository();
    final savedOverrides = await overrideRepo.loadOverrides(
      semesterId: term.id,
      accountId: '2403130233',
    );
    expect(savedOverrides, hasLength(1));
    expect(savedOverrides.first.toWeekday, 5);
    expect(savedOverrides.first.toStartSection, 3);

    provider.dispose();
  });
}

final class _FakeCourseRepository implements AcademicRepository {
  _FakeCourseRepository({
    required this.courses,
    this.courseStarted,
    this.courseGate,
  });

  final CourseFetchResult courses;
  final Completer<void>? courseStarted;
  final Completer<void>? courseGate;
  SessionState _state = SessionState.unauthenticated;
  String? _studentId;

  @override
  AcademicSourceKind get sourceKind => AcademicSourceKind.local;

  @override
  AcademicCapabilities get capabilities => const AcademicCapabilities.local();

  @override
  SessionState get sessionState => _state;

  @override
  String? get studentId => _studentId;

  @override
  String get sourceName => '测试本机直连';

  @override
  Future<void> switchSource(AcademicSourceKind source) async {}

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    _studentId = studentId;
    _state = SessionState.authenticated;
    return LoginSuccess(studentId: studentId, cookieNames: const {'test'});
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    throw const ProtocolChangedException(message: '测试未配置验证码');
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    return LoginSuccess(
      studentId: _studentId ?? '2403130233',
      cookieNames: const {'test'},
    );
  }

  @override
  Future<StudentProfile> getProfile() async => const StudentProfile(
        name: '测试同学',
        grade: '2026',
        college: '信息学院',
        major: '软件工程',
      );

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
    String? providerTermId,
  }) async {
    courseStarted?.complete();
    if (courseGate != null) await courseGate!.future;
    return courses;
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async =>
      GradeFetchResult(grades: const [], pages: 1);

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) async {
    throw UnimplementedError('测试未实现成绩详情');
  }

  @override
  Future<AcademicSituation> getAcademicSituation() async {
    throw UnimplementedError('测试未实现学业情况');
  }

  @override
  Future<CreditRequirement> getCreditRequirements() async {
    throw UnimplementedError('测试未实现学分要求');
  }

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> resetSession() async {
    _state = SessionState.unauthenticated;
    _studentId = null;
  }

  @override
  void close() {}
}
