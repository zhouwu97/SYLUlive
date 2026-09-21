import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

import 'helpers/personal_snapshot_test_fakes.dart';

/// 可控故障的文件后端：可精确让「一次写入之后的第一次读取」失败，或让其后所有读取持续失败。
///
/// 为什么在文件后端注入而不是在 provider 里注入：切学期的本地读取链路是
/// switchTerm → _readTermSnapshotStrict → store.readTerm → readSnapshot → 文件后端读，
/// 在这里注入才能真实走完整条读取路径，而不是绕过它去替换上层方法。
class _FaultInjectableFileBackend extends MemoryPersonalSnapshotFileBackend {
  bool _sawWrite = false;
  bool failNextReadAfterFirstWrite = false;
  bool failAllReadsAfterFirstWrite = false;
  bool _failNextWrite = false;

  int readCount = 0;
  int writeCount = 0;
  int failedReads = 0;

  /// 从现在开始：本后端此前是否写过快照一律不算数，
  /// 以 switchTerm 内部那次「选中学期」写入作为唯一的分界点。
  void armAfterNextWrite({required bool failOnlyOnce}) {
    _sawWrite = false;
    readCount = 0;
    failedReads = 0;
    failNextReadAfterFirstWrite = failOnlyOnce;
    failAllReadsAfterFirstWrite = !failOnlyOnce;
  }

  /// 让**下一次写入**失败，用于验证「选中学期落盘失败」路径。
  ///
  /// switchTerm 的第一次写入就是「选中学期」，因此在切学期开始时武装即等价于
  /// 「在任何课表/开学日写入之前就失败」。
  void armNextWriteFailure() {
    _failNextWrite = true;
  }

  /// 停止注入故障，用于验证故障之后数据是否仍然完好可读。
  void disarm() {
    failNextReadAfterFirstWrite = false;
    failAllReadsAfterFirstWrite = false;
    _failNextWrite = false;
  }

  bool get _shouldFail {
    if (!_sawWrite) return false;
    if (failAllReadsAfterFirstWrite) return true;
    return failNextReadAfterFirstWrite && failedReads == 0;
  }

  @override
  Future<Uint8List?> read({
    required String accountHash,
    required PersonalDataType type,
  }) async {
    readCount++;
    if (_shouldFail) {
      failedReads++;
      throw StateError('测试：本地课表快照读取失败');
    }
    return super.read(accountHash: accountHash, type: type);
  }

  @override
  Future<void> write({
    required String accountHash,
    required PersonalDataType type,
    required Uint8List bytes,
  }) async {
    if (_failNextWrite) {
      _failNextWrite = false;
      throw StateError('测试：本地课表快照写入失败');
    }
    await super.write(accountHash: accountHash, type: type, bytes: bytes);
    writeCount++;
    _sawWrite = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPersonalSnapshotSecureStore secureStore;
  late _FaultInjectableFileBackend files;
  late IncrementingRandomBytes random;

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
  final startA = DateTime(2025, 9, 1);
  final startB = DateTime(2026, 3, 2);

  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    final preferences = await AppPreferencesStore.getInstance();
    for (final studentId in ['2403130233', '2403130234']) {
      final identity = AcademicIdentityKey(
        appUserId: '1001',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: studentId,
      );
      await preferences.setBool(
          'academic_lifecycle_${identity.storageId}_connected', true);
    }
    AcademicPersistenceRegistry.set('1001', enabled: true);
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = _FaultInjectableFileBackend();
    random = IncrementingRandomBytes();
  });

  tearDown(() {
    AcademicPersistenceRegistry.clear('1001');
  });

  CourseScheduleProvider createProvider([Dio? dio]) {
    return CourseScheduleProvider(
      dio,
      (appUserId) => AesGcmAccountScopedSnapshotStore(
        appUserId: appUserId,
        secureStore: secureStore,
        fileBackend: files,
        randomBytes: random.call,
      ),
    );
  }

  /// 播种 A、B 两个学期的课程与开学周，返回一个已就绪的 provider。
  Future<CourseScheduleProvider> seedTwoTerms([Dio? dio]) async {
    final provider = createProvider(dio)
      ..syncSessionContext('1001', '2403130233');
    for (var i = 0; i < 40 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(provider.isSessionReady, isTrue, reason: '播种前会话应已就绪');
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
    return provider;
  }

  test('SCHED-02 首次本地读取失败时真正重读一次并恢复目标学期，且不发起学校请求', () async {
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options.uri.toString());
          handler.next(options);
        },
      ));
    final provider = await seedTwoTerms(dio);
    addTearDown(provider.dispose);

    // 先切到 B，确保接下来切回 A 是一次真实的跨学期读取。
    expect(await provider.switchTerm(termB), isTrue);
    expect(provider.courses.single.name, '学期 B 课程');

    files.armAfterNextWrite(failOnlyOnce: true);
    final ok = await provider.switchTerm(termA);

    expect(files.failedReads, 1, reason: '注入的失败只应发生一次');
    expect(ok, isTrue, reason: '首次本地读取失败必须触发一次本地重读并最终成功');
    expect(provider.isSessionReady, isTrue);
    expect(provider.isLoading, isFalse);
    expect(provider.currentTerm.id, termA.id);
    expect(provider.courses.single.name, '学期 A 课程',
        reason: '重读成功后必须提交目标学期的课程，而不是停在空课表');
    expect(provider.semesterStart, startA, reason: '重读成功后应恢复目标学期的开学周');
    expect(provider.errorMessage, isNull);
    expect(files.readCount, greaterThanOrEqualTo(3),
        reason: '失败之后必须再读一次才可能拿到快照');
    expect(requests, isEmpty, reason: '切学期是纯本地读取，不应产生任何学校请求');
  });

  test('SCHED-03 目标学期本地读取连续失败：保留错误态与两学期数据，不呈现为空课表', () async {
    final provider = await seedTwoTerms();
    addTearDown(provider.dispose);

    expect(await provider.switchTerm(termB), isTrue);
    final vaultEntriesBeforeFailure = Map.of(files.values)
      ..removeWhere((_, __) => false);
    expect(vaultEntriesBeforeFailure, isNotEmpty);

    files.armAfterNextWrite(failOnlyOnce: false);
    final ok = await provider.switchTerm(termA);

    expect(ok, isFalse, reason: '读取持续失败时不得报告切换成功');
    expect(provider.isLoading, isFalse, reason: 'loading 必须结束，不能一直挂在加载态');
    expect(provider.errorMessage, isNotNull,
        reason: '必须给出可恢复的错误态，而不是静默呈现为「该学期没有课表」');
    expect(provider.sessionPhase, ScheduleSessionPhase.restoreFailed,
        reason: '读取失败时不能向页面宣告已 ready');
    expect(provider.isSessionReady, isFalse);

    // 关键：失败不能删除或损坏任何一方的密文。这里不比较字节相等——
    // 失败发生前「选中学期」已经成功持久化，密文本来就会变；
    // 真正要证明的是两个学期的课程与开学周都还能读回来。
    expect(files.values.keys.toSet(), vaultEntriesBeforeFailure.keys.toSet(),
        reason: '读取失败不得删除任何一条本机快照记录');

    files.disarm();
    expect(await provider.switchTerm(termB), isTrue);
    expect(provider.courses.single.name, '学期 B 课程');
    expect(provider.semesterStart, startB, reason: 'B 的开学周必须仍然可读');
    expect(await provider.switchTerm(termA), isTrue);
    expect(provider.courses.single.name, '学期 A 课程');
    expect(provider.semesterStart, startA, reason: 'A 的开学周必须仍然可读');
  });

  test('SCHED-03b 读取失败后重试可恢复，且不把失败当成「目标学期没有日期」', () async {
    final provider = await seedTwoTerms();
    addTearDown(provider.dispose);

    expect(await provider.switchTerm(termA), isTrue);
    expect(provider.semesterStart, startA);

    files.armAfterNextWrite(failOnlyOnce: false);
    await provider.switchTerm(termA);

    expect(provider.errorMessage, isNotNull);
    expect(provider.sessionPhase, ScheduleSessionPhase.restoreFailed);
    // 失败态下不得把 B 的日期冒充成 A 的日期。
    expect(provider.semesterStart, isNot(startB));

    // 用户点「重试恢复」：故障消失后必须能读回 A 自己的课程与开学周。
    files.disarm();
    expect(await provider.switchTerm(termA), isTrue);
    expect(provider.errorMessage, isNull);
    expect(provider.isSessionReady, isTrue);
    expect(provider.courses.single.name, '学期 A 课程');
    expect(provider.semesterStart, startA, reason: '读取失败不得把已保存的开学周清掉，重试后必须恢复');
  });

  test('SCHED-05 选中学期落盘失败：回退到原学期，不得留下「学期与课程不一致」的混合状态', () async {
    final provider = await seedTwoTerms();
    addTearDown(provider.dispose);

    // 先稳定停在 A。
    expect(await provider.switchTerm(termA), isTrue);
    expect(provider.currentTerm.id, termA.id);
    expect(provider.courses.single.name, '学期 A 课程');
    final startBefore = provider.semesterStart;
    final entriesBefore = Map.of(files.values);

    // 切学期最早的写入就是「选中学期」：它在任何课表/开学日写入之前失败。
    files.armNextWriteFailure();
    final ok = await provider.switchTerm(termB);

    expect(ok, isFalse, reason: '选中学期都存不下时不得报告切换成功');
    expect(provider.currentTerm.id, termA.id,
        reason: '落盘失败必须回退到原学期，不能停在「学期已是 B、课程还是 A」的混合状态');
    expect(provider.courses.single.name, '学期 A 课程',
        reason: '课程仍是 A 的，学期也必须保持一致');
    expect(provider.semesterStart, startBefore, reason: '开学周不得被清掉');
    expect(provider.errorMessage, '本机课表暂时无法切换学期，请稍后重试');
    expect(files.values, entriesBefore, reason: '失败的写入不得落盘，密文记录集合必须保持不变');

    // 故障消失后仍可正常切换，且两个学期的数据都完好。
    expect(await provider.switchTerm(termB), isTrue);
    expect(provider.currentTerm.id, termB.id);
    expect(provider.courses.single.name, '学期 B 课程');
    expect(provider.semesterStart, startB);
    expect(await provider.switchTerm(termA), isTrue);
    expect(provider.courses.single.name, '学期 A 课程');
    expect(provider.semesterStart, startA);
  });

  test('SCHED-04 目标学期明确缺失与合法空快照都与读取失败可区分，且 loading 正常结束', () async {
    const manyTerms = CourseTerm(
      id: '2026_1',
      year: '2026',
      semester: 1,
      title: '2026-2027 第一学期',
      maxWeek: 20,
    );
    final provider = await seedTwoTerms();
    addTearDown(provider.dispose);

    // 情形一：目标学期完全没有本地快照（明确缺失）。
    expect(await provider.switchTerm(manyTerms, loadCache: true), isFalse,
        reason: '没有本地课表时切换本身不算成功');
    expect(provider.isLoading, isFalse);
    expect(provider.errorMessage, isNull, reason: '明确缺失不是错误，不能展示可恢复错误态');
    expect(provider.sessionPhase, ScheduleSessionPhase.ready,
        reason: '明确缺失是正常结果，会话应进入 ready');
    expect(provider.courses, isEmpty);
    expect(provider.semesterStart, isNull, reason: '目标学期确实没有日期时才允许把日期视为未设置');

    // 情形二：目标学期存在合法但课程为空的快照。
    await provider.applyFetchedCoursesForTerm(term: manyTerms, rawCourses: []);
    expect(await provider.switchTerm(termA), isTrue);
    await provider.switchTerm(manyTerms, loadCache: true);
    expect(provider.isLoading, isFalse);
    expect(provider.errorMessage, isNull, reason: '合法空快照是有效结果，不是读取失败');
    expect(provider.sessionPhase, ScheduleSessionPhase.ready);
  });
}
