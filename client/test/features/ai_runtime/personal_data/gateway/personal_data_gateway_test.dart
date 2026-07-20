import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/adapters/erke_gateway_adapter.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/adapters/physical_gateway_adapter.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/gateway_result.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_account_context.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_data_gateway_impl.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

import '../../../../helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const appUserId = 'gateway-user';
  const sourceAccountId = 'gateway-source';

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() {
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
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
