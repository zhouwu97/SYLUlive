import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/adapters/academic_gateway_adapter.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/adapters/erke_gateway_adapter.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/adapters/physical_gateway_adapter.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/adapters/schedule_gateway_adapter.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/gateway_result.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_account_context.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_data_gateway_impl.dart';
import 'package:shenliyuan/features/campus_data/storage/academic_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

import '../../../../helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const appUserId = 'gateway-user';
  const sourceAccountId = 'gateway-source';

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
    AcademicPersistenceRegistry.set(appUserId, enabled: true);
  });

  AesGcmAccountScopedSnapshotStore createVault([String user = appUserId]) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: user,
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
  }

  PersonalDataGatewayImpl createGateway({
    required PersonalAccountContext context,
    required AccountScopedSnapshotStore snapshotStore,
    Future<bool> Function()? erkeNeedsResync,
    Future<bool> Function()? physicalNeedsResync,
    AccountSessionCleanupCoordinator? cleanupCoordinator,
  }) {
    return PersonalDataGatewayImpl(
      context: context,
      snapshotStore: snapshotStore,
      erkeAdapter: ErkeGatewayAdapter(
        snapshotStore: snapshotStore,
        context: context,
        needsResync: erkeNeedsResync,
      ),
      physicalAdapter: PhysicalGatewayAdapter(
        snapshotStore: snapshotStore,
        context: context,
        needsResync: physicalNeedsResync,
      ),
      scheduleAdapter: ScheduleGatewayAdapter(
        cacheStore: ScheduleCacheStore(
          appUserId: context.appUserId,
          sourceAccountId: context.sourceAccountId,
          snapshotStore: snapshotStore,
        ),
      ),
      academicAdapter: AcademicGatewayAdapter(
        cacheStore: AcademicCacheStore(
          appUserId: context.appUserId,
          sourceAccountId: context.sourceAccountId,
          snapshotStore: snapshotStore,
        ),
      ),
      cleanupCoordinator: cleanupCoordinator,
    );
  }

  test('二课密文快照返回最小化概览和新鲜度元数据', () async {
    final vault = createVault();
    final fetchedAt = DateTime.utc(2026, 7, 20, 8);
    final expiresAt = DateTime.now().toUtc().add(const Duration(days: 1));
    await vault.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: sourceAccountId,
      fetchedAt: fetchedAt,
      expiresAt: expiresAt,
      payload: _erkePayload(),
    );

    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getErkeOverview();

    expect(result.status, GatewayStatus.available);
    expect(result.source, PersonalDataSource.localEncryptedVault);
    expect(result.data?.activityCount, 2);
    expect(result.data?.earnedTotal, 16);
    expect(result.data?.graduationGap, 4);
    expect(result.data?.categories.single.code, 'A');
    expect(result.data?.latestActivityDate, '2026-07-19');
    expect(result.fetchedAt, fetchedAt);
    expect(result.expiresAt, expiresAt);
    expect(result.isStale, isFalse);
  });

  test('体测密文快照只返回最近学年和项目概览', () async {
    final vault = createVault();
    await vault.write(
      type: PersonalDataType.physical,
      schemaVersion: 2,
      sourceSystem: 'physical',
      sourceAccountId: sourceAccountId,
      payload: _physicalPayload(),
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getPhysicalOverview();

    expect(result.status, GatewayStatus.available);
    expect(result.data?.latestYear, '2026');
    expect(result.data?.availableYears, <String>['2026', '2025']);
    expect(result.data?.totalScore, 91.5);
    expect(result.data?.metrics.single.name, '肺活量');
    expect(result.data?.metrics.single.score, 92);
  });

  test('来源账号变化时不会读取当前用户的旧快照', () async {
    final vault = createVault();
    await vault.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: sourceAccountId,
      payload: _erkePayload(),
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: 'another-source',
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getErkeOverview();

    expect(result.status, GatewayStatus.missing);
    expect(result.data, isNull);
    expect(result.source, PersonalDataSource.none);
  });

  test('过期快照保留概览但明确标记需要同步', () async {
    final vault = createVault();
    final expiresAt =
        DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await vault.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: sourceAccountId,
      expiresAt: expiresAt,
      payload: _erkePayload(),
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getErkeOverview();

    expect(result.status, GatewayStatus.stale);
    expect(result.data, isNotNull);
    expect(result.isStale, isTrue);
    expect(result.expiresAt, expiresAt);
    expect(result.warnings, isNotEmpty);
  });

  test('篡改 AES-GCM 密文时 Gateway 失败关闭且不返回对象', () async {
    final vault = createVault();
    await vault.write(
      type: PersonalDataType.erke,
      schemaVersion: 2,
      sourceSystem: 'erke',
      sourceAccountId: sourceAccountId,
      payload: _erkePayload(),
    );
    final fileKey = files.key(vault.accountFingerprint, PersonalDataType.erke);
    final envelope =
        jsonDecode(utf8.decode(files.values[fileKey]!)) as Map<String, dynamic>;
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    ciphertext[ciphertext.length ~/ 2] ^= 0x01;
    envelope['ciphertext'] = base64Encode(ciphertext);
    files.values[fileKey] = Uint8List.fromList(
      utf8.encode(jsonEncode(envelope)),
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getErkeOverview();

    expect(result.status, GatewayStatus.corrupted);
    expect(result.data, isNull);
    expect(result.error?.code.name, 'corrupted');
  });

  test('Gateway 与 Vault 账号指纹不一致时拒绝读取', () async {
    final mismatchedStore = YieldingPersonalSnapshotStore(
      accountFingerprint: 'another-account-fingerprint',
    );
    final context = PersonalAccountContext(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
    );
    final gateway = createGateway(
      context: context,
      snapshotStore: mismatchedStore,
    );

    final result = await gateway.getPhysicalOverview();

    expect(result.status, GatewayStatus.accountMismatch);
    expect(result.data, isNull);
    expect(result.error?.code.name, 'accountMismatch');
  });

  test('统一账号清理后旧 Gateway 立即关闭', () async {
    final coordinator = AccountSessionCleanupCoordinator();
    final vault = createVault();
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
      cleanupCoordinator: coordinator,
    );

    await coordinator.closeCurrentSession();
    final result = await gateway.getPhysicalOverview();

    expect(result.status, GatewayStatus.closed);
    expect(result.data, isNull);
    expect(result.error?.code.name, 'closed');
  });

  test('读取期间关闭账号时不会返回旧上下文的数据', () async {
    final context = PersonalAccountContext(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
    );
    final delayedStore = _DelayedSnapshotStore(
      accountFingerprint: context.appUserFingerprint,
    );
    final gateway = createGateway(
      context: context,
      snapshotStore: delayedStore,
    );

    final pending = gateway.getErkeOverview();
    await delayedStore.readStarted.future;
    await gateway.close();
    delayedStore.complete(
      PersonalSnapshot(
        appUserFingerprint: context.appUserFingerprint,
        sourceAccountFingerprint: 'verified-source-fingerprint',
        type: PersonalDataType.erke,
        schemaVersion: 2,
        encryptionVersion: 1,
        fetchedAt: DateTime.utc(2026, 7, 20),
        contentHash: 'verified-content-hash',
        payload: _erkePayload(),
      ),
    );

    final result = await pending;

    expect(result.status, GatewayStatus.closed);
    expect(result.data, isNull);
  });

  test('密文缺失且需要重新同步时返回 needsRefresh', () async {
    final vault = createVault();
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
      physicalNeedsResync: () async => true,
    );

    final result = await gateway.getPhysicalOverview();

    expect(result.status, GatewayStatus.needsRefresh);
    expect(result.data, isNull);
    expect(result.warnings, isNotEmpty);
  });

  test('课表 Gateway 只返回指定日期范围内的最小化课程出现项', () async {
    final vault = createVault();
    final scheduleStore = ScheduleCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await scheduleStore.writeSemesterStart(
      year: '2026',
      semester: 3,
      semesterStart: DateTime.utc(2026, 9, 7),
    );
    await scheduleStore.writeCourses(
      year: '2026',
      semester: 3,
      courses: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 12,
          'course_code': 'MATH-101',
          'name': '离散数学',
          'teacher': '张老师',
          'location': 'A101',
          'color': '#6366F1',
          'weekday': 1,
          'start_section': 1,
          'end_section': 2,
          'weeks': <int>[1, 2],
          'note': '内部备注',
        },
      ],
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2026, 9, 7),
      end: DateTime.utc(2026, 9, 7),
    );

    expect(result.status, GatewayStatus.available);
    expect(result.source, PersonalDataSource.localEncryptedVault);
    expect(result.data?.occurrences, hasLength(1));
    final occurrence = result.data!.occurrences.single;
    expect(occurrence.courseName, '离散数学');
    expect(occurrence.teacher, '张老师');
    expect(occurrence.location, 'A101');
    expect(occurrence.startSection, 1);
    expect(occurrence.endSection, 2);
  });

  test('新学期开始后不返回旧学期的不限周次课程', () async {
    final vault = createVault();
    final scheduleStore = ScheduleCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2025',
      semester: 3,
      start: DateTime.utc(2025, 9, 1),
      courseName: '旧学期课程',
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2026',
      semester: 3,
      start: DateTime.utc(2026, 3, 2),
      courseName: '新学期课程',
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2026, 3, 2),
      end: DateTime.utc(2026, 3, 2),
    );

    expect(result.status, GatewayStatus.available);
    expect(result.data?.occurrences, hasLength(1));
    expect(result.data?.occurrences.single.courseName, '新学期课程');
    expect(result.data?.occurrences.single.semesterId, '2026_3');
  });

  test('课表 Gateway 在跨学期范围内仅返回各自学期课程', () async {
    final vault = createVault();
    final scheduleStore = ScheduleCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2025',
      semester: 3,
      start: DateTime.utc(2025, 9, 1),
      courseName: '旧学期课程',
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2026',
      semester: 3,
      start: DateTime.utc(2026, 3, 2),
      courseName: '新学期课程',
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2026, 2, 23),
      end: DateTime.utc(2026, 3, 2),
    );

    expect(result.status, GatewayStatus.available);
    expect(
      result.data?.occurrences.map((item) => item.courseName).toList(),
      <String>['旧学期课程', '新学期课程'],
    );
    expect(
      result.data?.occurrences.map((item) => item.semesterId).toList(),
      <String>['2025_3', '2026_3'],
    );
  });

  test('课表学期起始日重复时失败关闭', () async {
    final vault = createVault();
    final scheduleStore = ScheduleCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2025',
      semester: 3,
      start: DateTime.utc(2026, 9, 7),
      courseName: '课程一',
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2026',
      semester: 3,
      start: DateTime.utc(2026, 9, 7),
      courseName: '课程二',
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2026, 9, 7),
      end: DateTime.utc(2026, 9, 7),
    );

    expect(result.status, GatewayStatus.corrupted);
    expect(result.data, isNull);
  });

  test('最后学期超过 26 周后不再延续不限周次课程', () async {
    final vault = createVault();
    final scheduleStore = ScheduleCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await _writeScheduleTerm(
      scheduleStore,
      year: '2026',
      semester: 3,
      start: DateTime.utc(2026, 9, 7),
      courseName: '本学期课程',
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2027, 3, 8),
      end: DateTime.utc(2027, 3, 8),
    );

    expect(result.status, GatewayStatus.available);
    expect(result.data?.occurrences, isEmpty);
  });

  test('课表 Gateway 拒绝超过上限的读取范围', () async {
    final vault = createVault();
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2026, 9, 1),
      end: DateTime.utc(2026, 10, 2),
    );

    expect(result.status, GatewayStatus.unsupported);
    expect(result.data, isNull);
  });

  test('成绩 Gateway 只返回学期覆盖和数量', () async {
    final vault = createVault();
    final academicStore = AcademicCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await academicStore.writeGrades(
      year: '2025',
      semester: 3,
      grades: <Map<String, dynamic>>[
        <String, dynamic>{
          'name': '数据结构',
          'grade': '93',
          'credits': 4,
          'gpa': 4.0,
          'is_degree': true,
        },
      ],
    );
    await academicStore.writeAcademicSituation(
      data: <String, dynamic>{
        'success': true,
        'total_courses': 1,
        'courses': <Map<String, dynamic>>[],
      },
    );
    await academicStore.markGradeSyncComplete();
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getAcademicOverview();

    expect(result.status, GatewayStatus.available);
    expect(result.data?.totalRecordedCourses, 1);
    expect(result.data?.terms, hasLength(1));
    expect(result.data?.terms.single.year, '2025');
    expect(result.data?.terms.single.semester, 3);
    expect(result.data?.hasAcademicSituation, isTrue);
  });

  test('来源账号变化后课表和成绩均不返回旧数据', () async {
    final vault = createVault();
    final scheduleStore = ScheduleCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    );
    await scheduleStore.writeCourses(
      year: '2026',
      semester: 3,
      courses: const <Map<String, dynamic>>[],
    );
    await AcademicCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      snapshotStore: vault,
    ).writeGrades(
      year: '2026',
      semester: 3,
      grades: <Map<String, dynamic>>[
        <String, dynamic>{'name': '课程', 'grade': '90'},
      ],
    );
    final changedSourceGateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: 'another-source',
      ),
      snapshotStore: vault,
    );

    final schedule = await changedSourceGateway.getScheduleOverview(
      start: DateTime.utc(2026, 9, 1),
      end: DateTime.utc(2026, 9, 1),
    );
    final academic = await changedSourceGateway.getAcademicOverview();

    expect(schedule.status, GatewayStatus.missing);
    expect(schedule.data, isNull);
    expect(academic.status, GatewayStatus.missing);
    expect(academic.data, isNull);
  });

  test('未知课表快照版本失败关闭，不返回旧课程', () async {
    final vault = createVault();
    await vault.write(
      type: PersonalDataType.schedule,
      schemaVersion: 99,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
      payload: <String, dynamic>{
        'terms': <String, dynamic>{
          '2026_3': <String, dynamic>{
            'courses': <Map<String, dynamic>>[],
            'hidden_course_ids': <int>[],
            'semester_start': null,
            'archives': <Map<String, dynamic>>[],
            'active_archive_id': null,
          },
        },
      },
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getScheduleOverview(
      start: DateTime.utc(2026, 9, 7),
      end: DateTime.utc(2026, 9, 7),
    );

    expect(result.status, GatewayStatus.corrupted);
    expect(result.data, isNull);
  });

  test('未知成绩快照版本失败关闭，不返回旧概览', () async {
    final vault = createVault();
    await vault.write(
      type: PersonalDataType.academic,
      schemaVersion: 99,
      sourceSystem: 'edu',
      sourceAccountId: sourceAccountId,
      payload: <String, dynamic>{
        'grade_terms': <String, dynamic>{},
        'academic_situation': null,
      },
    );
    final gateway = createGateway(
      context: PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      snapshotStore: vault,
    );

    final result = await gateway.getAcademicOverview();

    expect(result.status, GatewayStatus.corrupted);
    expect(result.data, isNull);
  });
}

Map<String, dynamic> _erkePayload() => <String, dynamic>{
      'graduation': <String, dynamic>{
        'requiredTotal': 20,
        'earnedTotal': 16,
        'rawTotalGap': 4,
        'categoryGap': 4,
        'graduationGap': 4,
        'unmetCount': 1,
        'officialConclusion': '待完成',
        'categories': <Map<String, dynamic>>[
          <String, dynamic>{
            'code': 'A',
            'name': '思想成长',
            'required': 8,
            'earned': 4,
            'meetsNumerically': false,
          },
        ],
      },
      'yearly': <String, dynamic>{
        'year': '2026',
        'availableYears': <String>['2026'],
        'requiredTotal': 4,
        'yearEarnedTotal': 2,
        'cumulativeTotal': 16,
        'rawYearGap': 2,
        'categoryGap': 2,
        'minimumGap': 2,
        'officialConclusion': '待完成',
        'categories': <Map<String, dynamic>>[],
      },
      'yearlyByYear': <String, dynamic>{},
      'activities': <Map<String, dynamic>>[
        <String, dynamic>{
          'item': '志愿服务',
          'score': '2',
          'date': '2026-07-19',
          'category': 'A',
        },
        <String, dynamic>{
          'item': '校园活动',
          'score': '1',
          'date': '2026-07-01',
          'category': 'B',
        },
      ],
      'activitiesByYear': <String, dynamic>{},
    };

Map<String, dynamic> _physicalPayload() => <String, dynamic>{
      'years': <String, dynamic>{
        '2025': <String, dynamic>{
          'total_grade': '合格',
          'total_score': 82,
          'scores': <Map<String, dynamic>>[],
        },
        '2026': <String, dynamic>{
          'total_grade': '良好',
          'total_score': 91.5,
          'scores': <Map<String, dynamic>>[
            <String, dynamic>{
              'sub_name': '肺活量',
              'result': '4200',
              'grade': '良好',
              'score': 92,
            },
          ],
        },
      },
    };

Future<void> _writeScheduleTerm(
  ScheduleCacheStore store, {
  required String year,
  required int semester,
  required DateTime start,
  required String courseName,
}) async {
  await store.writeSemesterStart(
    year: year,
    semester: semester,
    semesterStart: start,
  );
  await store.writeCourses(
    year: year,
    semester: semester,
    courses: <Map<String, dynamic>>[
      <String, dynamic>{
        'name': courseName,
        'weekday': 1,
        'start_section': 1,
        'end_section': 2,
        'weeks': <int>[],
      },
    ],
  );
}

class _DelayedSnapshotStore implements AccountScopedSnapshotStore {
  _DelayedSnapshotStore({required this.accountFingerprint});

  @override
  final String accountFingerprint;

  final Completer<void> readStarted = Completer<void>();
  final Completer<PersonalSnapshot?> _result = Completer<PersonalSnapshot?>();

  void complete(PersonalSnapshot? snapshot) => _result.complete(snapshot);

  @override
  Future<void> clearUser() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteType(PersonalDataType type) async {}

  @override
  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  }) {
    readStarted.complete();
    return _result.future;
  }

  @override
  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) async {}
}
