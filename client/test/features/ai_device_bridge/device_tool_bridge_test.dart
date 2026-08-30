import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_automation_gateway.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_job_client.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_job_models.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_tool_bridge_host.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_tool_registry.dart';
import 'package:shenliyuan/features/ai_device_bridge/device_tool_worker.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/gateway_result.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/gateway/personal_data_gateway.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/academic_records.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/erke_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/physical_overview.dart';
import 'package:shenliyuan/features/ai_runtime/personal_data/models/schedule_overview.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_repository.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_coordinator.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_result.dart';
import 'package:shenliyuan/services/webvpn_service.dart';

void main() {
  final now = DateTime.now().toUtc();

  test('只执行白名单工具并返回裁剪后的结果信封', () async {
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
    );
    final result = await DeviceToolRegistry().execute(
      _job(now),
      gateway,
    );

    expect(result.value.keys, {
      'data',
      'source',
      'fetched_at',
      'expires_at',
      'is_stale',
      'is_partial',
      'warnings',
      'evidence',
    });
    expect(result.value['source'], 'device_encrypted_cache');
    expect((result.value['data'] as Map<String, dynamic>).keys, {
      'total_recorded_courses',
      'covered_term_count',
      'covered_terms',
      'academic_situation_available',
    });
    expect(jsonEncode(result.value), isNot(contains('sourceAccountId')));

    final unsupported = _job(now, toolName: 'device.not_allowed');
    expect(
      () => DeviceToolRegistry().execute(unsupported, gateway),
      throwsA(isA<DeviceToolExecutionException>()),
    );
  });

  test('体测设备工具只返回最近概览并支持刷新证据', () async {
    final fetchedAt = DateTime.now().toUtc();
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(fetchedAt),
      physicalOverview: GatewayResult<PhysicalOverview>(
        status: GatewayStatus.available,
        source: PersonalDataSource.deviceEncryptedCache,
        fetchedAt: fetchedAt,
        expiresAt: fetchedAt.add(const Duration(days: 30)),
        data: const PhysicalOverview(
          latestYear: '2026',
          availableYears: <String>['2026'],
          totalGrade: '良好',
          totalScore: 82.5,
          metrics: <PhysicalMetricOverview>[
            PhysicalMetricOverview(
              name: '50 米跑',
              result: '7.2 秒',
              grade: '良好',
              score: 82,
            ),
          ],
        ),
      ),
    );
    final freshness = EnsureFreshResult(
      before: FreshnessState(
        fetchedAt: fetchedAt.subtract(const Duration(days: 31)),
        expiresAt: fetchedAt.subtract(const Duration(days: 1)),
        isStale: true,
      ),
      after: FreshnessState(
        fetchedAt: fetchedAt,
        expiresAt: fetchedAt.add(const Duration(days: 30)),
        isStale: false,
      ),
      refreshPerformed: true,
    );
    final result = await DeviceToolRegistry().execute(
      DeviceToolJob(
        id: 'physical-job',
        toolName: 'device.physical.ensure_fresh_overview',
        arguments: const <String, dynamic>{'max_age_seconds': 86400},
        requiredDataTypes: const <String>['physical'],
        status: 'pending',
        stateVersion: 0,
        expiresAt: fetchedAt.add(const Duration(minutes: 1)),
      ),
      null,
      automationGateway: _FakeAutomationGateway(
        gateway,
        ensured: freshness,
      ),
    );

    expect(result.value['refresh_performed'], isTrue);
    final data = result.value['data'] as Map<String, dynamic>;
    expect(data['latest_year'], '2026');
    expect(data['total_score'], 82.5);
    expect((data['metrics'] as List), hasLength(1));
  });

  test('用户拒绝授权时任务失败且不读取本地缓存', () async {
    final job = _job(now);
    final api = _FakeDeviceJobApi(pendingJobs: [job]);
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
    );
    final worker = DeviceToolWorker(
      client: api,
      installationIdProvider: () async => 'installation-1',
      contextResolver: () async => _context(gateway),
      permissionResolver: (_) async => DeviceToolPermissionDecision.deny,
    );

    await worker.syncPending();

    expect(api.claimedJobIDs, [job.id]);
    expect(api.failed, [('job-1', 'permission_denied')]);
    expect(gateway.academicReadCount, 0);
    expect(api.completedJobIDs, isEmpty);
  });

  test('账号上下文在读取期间失效时不回传旧缓存', () async {
    final job = _job(now);
    var isCurrent = true;
    final api = _FakeDeviceJobApi(pendingJobs: [job]);
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
      onAcademicRead: () => isCurrent = false,
    );
    final worker = DeviceToolWorker(
      client: api,
      installationIdProvider: () async => 'installation-1',
      contextResolver: () async => _context(
        gateway,
        isCurrent: () async => isCurrent,
      ),
      permissionResolver: (_) async => DeviceToolPermissionDecision.allow,
    );

    await worker.syncPending();

    expect(api.claimedJobIDs, [job.id]);
    expect(api.completedJobIDs, isEmpty);
    expect(api.failed, isEmpty);
    expect(gateway.closed, isTrue);
  });

  test('ensure_fresh 工具返回刷新证据并使用服务端结果来源', () async {
    final now = DateTime.now().toUtc();
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
    );
    final automation = _FakeAutomationGateway(
      gateway,
      ensured: EnsureFreshResult(
        before: FreshnessState(
          fetchedAt: now.subtract(const Duration(hours: 2)),
          expiresAt: now.subtract(const Duration(hours: 1)),
          isStale: true,
        ),
        after: FreshnessState(
          fetchedAt: now,
          expiresAt: now.add(const Duration(minutes: 5)),
          isStale: false,
        ),
        refreshPerformed: true,
      ),
    );

    final result = await DeviceToolRegistry().execute(
      DeviceToolJob(
        id: 'job-fresh',
        toolName: 'device.academic.ensure_fresh_overview',
        arguments: const {'max_age_seconds': 1},
        requiredDataTypes: const ['academic'],
        status: 'pending',
        stateVersion: 0,
        expiresAt: now.add(const Duration(minutes: 1)),
      ),
      null,
      automationGateway: automation,
    );

    expect(result.value['source'], 'remote_edu_fetch');
    expect(result.value['refresh_performed'], isTrue);
    expect(result.value['freshness'], {'before': 'stale', 'after': 'fresh'});
    expect(result.value['data'], isA<Map<String, dynamic>>());
  });

  test('学业 bundle 按三个数据集读取并返回嵌套审计信封', () async {
    final now = DateTime.now().toUtc();
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
      academicRecords: GatewayResult(
        status: GatewayStatus.available,
        source: PersonalDataSource.deviceEncryptedCache,
        fetchedAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
        data: AcademicRecords(
          courses: [
            CourseGradeRecord(
              courseId: 'course-1',
              courseName: '大学物理',
              credit: 3,
              nature: CourseNature.requiredCourse,
              attemptType: CourseAttemptType.normal,
              semesterId: '2025-1',
              score: 45,
            ),
          ],
        ),
      ),
    );
    final ensured = EnsureFreshResult(
      before: FreshnessState(
        fetchedAt: now.subtract(const Duration(days: 2)),
        expiresAt: now.subtract(const Duration(hours: 1)),
        isStale: true,
      ),
      after: FreshnessState(
        fetchedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
        isStale: false,
      ),
      refreshPerformed: true,
    );
    final automation = _FakeAutomationGateway(
      gateway,
      ensured: ensured,
      academicDatasets: {
        'academic_situation': {
          'total_courses': 10,
          'passed_courses': 8,
          'failed_courses': 1,
          'in_progress_courses': 1,
          'degree_total_courses': 40,
          'degree_passed_courses': 30,
          'degree_failed_courses': 1,
          'degree_in_progress_courses': 9,
          'all_gpa': 3.2,
        },
        'credit_requirements': {
          'required_credits': 160.0,
          'earned_credits': 120.0,
          'completed_credits': 120.0,
          'remaining_credits': 40.0,
          'credit_gap': 40.0,
          'module_count': 4,
        },
      },
    );

    final result = await DeviceToolRegistry().execute(
      DeviceToolJob(
        id: 'job-bundle',
        toolName: 'device.academic.ensure_fresh_bundle',
        arguments: const {
          'max_age_seconds': {
            'grades': 300,
            'academic_situation': 21600,
            'credit_requirements': 86400,
          },
        },
        requiredDataTypes: const [
          'grades',
          'academic_situation',
          'credit_requirements',
        ],
        status: 'pending',
        stateVersion: 0,
        expiresAt: now.add(const Duration(minutes: 1)),
      ),
      null,
      automationGateway: automation,
    );

    expect(result.value['source'], 'remote_edu_fetch');
    final data = result.value['data'] as Map<String, dynamic>;
    expect(data.keys, {
      'grades',
      'academic_situation',
      'credit_requirements',
    });
    expect(
      (data['academic_situation'] as Map<String, dynamic>)['data'],
      containsPair('all_gpa', 3.2),
    );
    expect(
      (data['credit_requirements'] as Map<String, dynamic>)['data'],
      containsPair('credit_gap', 40.0),
    );
  });

  test('同步期间再次触发会在当前批次结束后继续补拉', () async {
    final first = _job(now);
    final second = _jobWithId(
      now,
      id: 'job-2',
      toolName: 'device.academic.get_cached_overview',
    );
    final api = _RacingDeviceJobApi(first: first, second: second);
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
    );
    final worker = DeviceToolWorker(
      client: api,
      installationIdProvider: () async => 'installation-1',
      contextResolver: () async => _context(gateway),
      permissionResolver: (_) async => DeviceToolPermissionDecision.allow,
    );

    final firstSync = worker.syncPending();
    await api.firstPendingStarted.future;
    final secondSync = worker.syncPending();
    api.releaseFirstPending.complete();
    await Future.wait([firstSync, secondSync]);

    expect(api.pendingCalls, 2);
    expect(api.claimedJobIDs, ['job-1', 'job-2']);
    expect(api.completedJobIDs, ['job-1', 'job-2']);
  });

  test('凭据失败且暂时无法弹窗时转入 waiting_user，恢复后重新领取完成', () async {
    final job = _ensureFreshJob(now);
    final api = _FakeDeviceJobApi(pendingJobs: [job]);
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
    );
    final automation = _FakeAutomationGateway(
      gateway,
      ensured: _ensured(now),
      ensureFreshFailures: const [
        DeviceAutomationException('credential_unavailable', '二课密码尚未填写'),
      ],
    );
    final decisions = [
      DeviceToolPermissionDecision.allow,
      DeviceToolPermissionDecision.defer,
      DeviceToolPermissionDecision.allow,
    ];
    final worker = DeviceToolWorker(
      client: api,
      installationIdProvider: () async => 'installation-1',
      contextResolver: () async => _context(
        gateway,
        createAutomationGateway: () => automation,
      ),
      permissionResolver: (_) async => decisions.removeAt(0),
    );

    await worker.syncPending();

    expect(api.waitedJobIDs, [job.id]);
    expect(api.failed, isEmpty);
    expect(api.completedJobIDs, isEmpty);

    // 用户回到前台后，PendingJobs 重新带回 waiting_user 任务并继续完成。
    api.pendingJobs
      ..clear()
      ..add(_ensureFreshJob(now, status: 'waiting_user', stateVersion: 5));
    await worker.syncPending();

    expect(api.claimedJobIDs, [job.id, job.id]);
    expect(api.completedJobIDs, [job.id]);
    expect(api.failed, isEmpty);
  });

  test('凭据失败后用户取消密码框时按用户拒绝收尾', () async {
    final job = _ensureFreshJob(now);
    final api = _FakeDeviceJobApi(pendingJobs: [job]);
    final gateway = _FakeGateway(
      academicOverview: _academicOverviewResult(now),
    );
    final automation = _FakeAutomationGateway(
      gateway,
      ensured: _ensured(now),
      ensureFreshFailures: const [
        DeviceAutomationException('credential_unavailable', '二课密码尚未填写'),
      ],
    );
    final decisions = [
      DeviceToolPermissionDecision.allow,
      DeviceToolPermissionDecision.deny,
    ];
    final worker = DeviceToolWorker(
      client: api,
      installationIdProvider: () async => 'installation-1',
      contextResolver: () async => _context(
        gateway,
        createAutomationGateway: () => automation,
      ),
      permissionResolver: (_) async => decisions.removeAt(0),
    );

    await worker.syncPending();

    expect(api.failed, [(job.id, 'permission_denied')]);
    expect(api.waitedJobIDs, isEmpty);
    expect(api.completedJobIDs, isEmpty);
  });

  test('WebVPN 判定密码错误时二课同步标记凭据失败并允许清除', () async {
    final result = await _syncErkeWithVpnFailure(
      WebVpnLoginFailureType.invalidCredentials,
    );

    expect(result.status, PersonalSyncItemStatus.failed);
    expect(result.failureReason, PersonalSyncFailureReason.credentialUnavailable);
    expect(shouldClearErkeCredential(result.failureReason), isTrue);
  });

  test('WebVPN 网络失败时二课同步保留凭据', () async {
    final result = await _syncErkeWithVpnFailure(
      WebVpnLoginFailureType.unavailable,
    );

    expect(result.status, PersonalSyncItemStatus.failed);
    expect(result.failureReason, PersonalSyncFailureReason.networkUnavailable);
    expect(shouldClearErkeCredential(result.failureReason), isFalse);
  });

  test('未知二课失败与教务会话过期都不清除凭据', () async {
    final unknown = await _syncErkeWithVpnFailure(null);

    expect(unknown.failureReason, PersonalSyncFailureReason.unknown);
    expect(shouldClearErkeCredential(unknown.failureReason), isFalse);
    expect(
      shouldClearErkeCredential(PersonalSyncFailureReason.eduSessionExpired),
      isFalse,
    );
  });
}

Future<PersonalSyncItemResult> _syncErkeWithVpnFailure(
  WebVpnLoginFailureType? failureType,
) {
  final repository = ErkeRepository(
    vpnService: _ScriptedWebVpn(failureType),
    cacheStore:
        ErkeCacheStore(appUserId: 'user-1', sourceAccountId: 'source-1'),
  );
  return ErkeRepositoryPersonalSyncGateway(
    repository: repository,
    requestCredentials: () async => const PersonalErkeCredentials(
      studentId: 'source-1',
      casPassword: 'cas-pass',
      erkePassword: 'erke-pass',
    ),
  ).syncErke();
}

class _ScriptedWebVpn extends WebVpnService {
  _ScriptedWebVpn(this.failureType);

  final WebVpnLoginFailureType? failureType;

  @override
  Future<bool> login(String username, String password) async => false;

  @override
  String? get lastError => switch (failureType) {
        WebVpnLoginFailureType.invalidCredentials => '统一认证登录失败，请检查密码',
        WebVpnLoginFailureType.unavailable => 'WebVPN 网络连接失败，请检查网络后重试',
        _ => '统一认证流程异常，请稍后重试',
      };

  @override
  WebVpnLoginFailureType? get lastFailureType => failureType;
}

DeviceToolJob _job(
  DateTime now, {
  String toolName = 'device.academic.get_cached_overview',
}) {
  return DeviceToolJob(
    id: 'job-1',
    toolName: toolName,
    arguments: const <String, dynamic>{},
    requiredDataTypes: const ['academic'],
    status: 'pending',
    stateVersion: 0,
    expiresAt: now.add(const Duration(minutes: 1)),
  );
}

DeviceToolJob _jobWithId(
  DateTime now, {
  required String id,
  required String toolName,
}) {
  return DeviceToolJob(
    id: id,
    toolName: toolName,
    arguments: const <String, dynamic>{},
    requiredDataTypes: const ['academic'],
    status: 'pending',
    stateVersion: 0,
    expiresAt: now.add(const Duration(minutes: 1)),
  );
}

DeviceToolWorkerContext _context(
  PersonalDataGateway gateway, {
  Future<bool> Function()? isCurrent,
  DeviceAutomationGateway Function()? createAutomationGateway,
}) {
  return DeviceToolWorkerContext(
    appUserId: 'user-1',
    sourceAccountId: 'source-1',
    createGateway: () => gateway,
    isCurrent: isCurrent ?? () async => true,
    createAutomationGateway: createAutomationGateway,
  );
}

DeviceToolJob _ensureFreshJob(DateTime now, {String status = 'pending', int stateVersion = 0}) {
  return DeviceToolJob(
    id: 'job-1',
    toolName: 'device.academic.ensure_fresh_overview',
    arguments: const {'max_age_seconds': 300},
    requiredDataTypes: const ['academic'],
    status: status,
    stateVersion: stateVersion,
    expiresAt: now.add(const Duration(minutes: 1)),
  );
}

EnsureFreshResult _ensured(DateTime now) {
  return EnsureFreshResult(
    before: FreshnessState(
      fetchedAt: now.subtract(const Duration(hours: 2)),
      expiresAt: now.subtract(const Duration(hours: 1)),
      isStale: true,
    ),
    after: FreshnessState(
      fetchedAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
      isStale: false,
    ),
    refreshPerformed: true,
  );
}

GatewayResult<AcademicOverview> _academicOverviewResult(DateTime now) {
  return GatewayResult(
    status: GatewayStatus.available,
    source: PersonalDataSource.deviceEncryptedCache,
    fetchedAt: now,
    expiresAt: now.add(const Duration(days: 1)),
    data: AcademicOverview(
      totalRecordedCourses: 3,
      hasAcademicSituation: true,
      terms: [
        AcademicTermOverview(
          year: '2025-2026',
          semester: 3,
          courseCount: 3,
          fetchedAt: now,
        ),
      ],
    ),
  );
}

class _FakeDeviceJobApi implements DeviceJobApi {
  _FakeDeviceJobApi({required this.pendingJobs});

  List<DeviceToolJob> pendingJobs;
  final List<String> claimedJobIDs = [];
  final List<String> completedJobIDs = [];
  final List<String> waitedJobIDs = [];
  final List<(String, String)> failed = [];

  @override
  Future<DeviceToolJob> progress(
    String installationId,
    String jobId,
    int stateVersion,
    String stage,
  ) async {
    final pending = pendingJobs.singleWhere((job) => job.id == jobId);
    return DeviceToolJob(
      id: pending.id,
      toolName: pending.toolName,
      arguments: pending.arguments,
      requiredDataTypes: pending.requiredDataTypes,
      status: stage == 'refresh_started' ? 'running' : 'claimed',
      stateVersion: stateVersion + 1,
      expiresAt: pending.expiresAt,
    );
  }

  @override
  Future<DeviceToolJob> claim(
    String installationId,
    String jobId,
    int stateVersion,
  ) async {
    claimedJobIDs.add(jobId);
    final pending = pendingJobs.singleWhere((job) => job.id == jobId);
    return DeviceToolJob(
      id: pending.id,
      toolName: pending.toolName,
      arguments: pending.arguments,
      requiredDataTypes: pending.requiredDataTypes,
      status: 'claimed',
      stateVersion: stateVersion + 1,
      expiresAt: pending.expiresAt,
    );
  }

  @override
  Future<DeviceToolJob> waitForUser(
    String installationId,
    String jobId,
    int stateVersion,
  ) async {
    waitedJobIDs.add(jobId);
    final pending = pendingJobs.singleWhere((job) => job.id == jobId);
    return DeviceToolJob(
      id: pending.id,
      toolName: pending.toolName,
      arguments: pending.arguments,
      requiredDataTypes: pending.requiredDataTypes,
      status: 'waiting_user',
      stateVersion: stateVersion + 1,
      expiresAt: pending.expiresAt,
    );
  }

  @override
  Future<DeviceToolJob> complete(
    String installationId,
    String jobId,
    int stateVersion,
    Map<String, dynamic> result,
  ) async {
    completedJobIDs.add(jobId);
    return pendingJobs.singleWhere((job) => job.id == jobId);
  }

  @override
  Future<DeviceToolJob> fail(
    String installationId,
    String jobId,
    int stateVersion,
    String errorCode,
  ) async {
    failed.add((jobId, errorCode));
    return pendingJobs.singleWhere((job) => job.id == jobId);
  }

  @override
  Future<DeviceToolJob> get(String installationId, String jobId) async {
    return pendingJobs.singleWhere((job) => job.id == jobId);
  }

  @override
  Future<List<DeviceToolJob>> pending(String installationId) async =>
      pendingJobs;

  @override
  Future<void> register({
    required String installationId,
    required List<String> toolNames,
    required int bridgeProtocolVersion,
    required String clientVersion,
    String pushToken = '',
  }) async {}
}

class _RacingDeviceJobApi implements DeviceJobApi {
  _RacingDeviceJobApi({required this.first, required this.second});

  final DeviceToolJob first;
  final DeviceToolJob second;
  final Completer<void> firstPendingStarted = Completer<void>();
  final Completer<void> releaseFirstPending = Completer<void>();
  final List<String> claimedJobIDs = [];
  final List<String> completedJobIDs = [];
  int pendingCalls = 0;

  @override
  Future<List<DeviceToolJob>> pending(String installationId) async {
    pendingCalls += 1;
    if (pendingCalls == 1) {
      firstPendingStarted.complete();
      await releaseFirstPending.future;
      return [first];
    }
    return [second];
  }

  @override
  Future<DeviceToolJob> claim(
    String installationId,
    String jobId,
    int stateVersion,
  ) async {
    claimedJobIDs.add(jobId);
    final source = jobId == first.id ? first : second;
    return DeviceToolJob(
      id: source.id,
      toolName: source.toolName,
      arguments: source.arguments,
      requiredDataTypes: source.requiredDataTypes,
      status: 'claimed',
      stateVersion: stateVersion + 1,
      expiresAt: source.expiresAt,
    );
  }

  @override
  Future<DeviceToolJob> progress(
    String installationId,
    String jobId,
    int stateVersion,
    String stage,
  ) async {
    final source = jobId == first.id ? first : second;
    return DeviceToolJob(
      id: source.id,
      toolName: source.toolName,
      arguments: source.arguments,
      requiredDataTypes: source.requiredDataTypes,
      status: 'claimed',
      stateVersion: stateVersion + 1,
      expiresAt: source.expiresAt,
    );
  }

  @override
  Future<DeviceToolJob> complete(
    String installationId,
    String jobId,
    int stateVersion,
    Map<String, dynamic> result,
  ) async {
    completedJobIDs.add(jobId);
    return jobId == first.id ? first : second;
  }

  @override
  Future<DeviceToolJob> fail(
    String installationId,
    String jobId,
    int stateVersion,
    String errorCode,
  ) =>
      throw UnimplementedError();

  @override
  Future<DeviceToolJob> waitForUser(
    String installationId,
    String jobId,
    int stateVersion,
  ) =>
      throw UnimplementedError();

  @override
  Future<DeviceToolJob> get(String installationId, String jobId) =>
      throw UnimplementedError();

  @override
  Future<void> register({
    required String installationId,
    required List<String> toolNames,
    required int bridgeProtocolVersion,
    required String clientVersion,
    String pushToken = '',
  }) async {}
}

class _FakeGateway implements PersonalDataGateway {
  _FakeGateway({
    required this.academicOverview,
    this.academicRecords,
    this.physicalOverview,
    this.onAcademicRead,
  });

  final GatewayResult<AcademicOverview> academicOverview;
  final GatewayResult<AcademicRecords>? academicRecords;
  final GatewayResult<PhysicalOverview>? physicalOverview;
  final void Function()? onAcademicRead;
  int academicReadCount = 0;
  bool closed = false;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<GatewayResult<AcademicOverview>> getAcademicOverview() async {
    academicReadCount += 1;
    onAcademicRead?.call();
    return academicOverview;
  }

  @override
  Future<GatewayResult<AcademicRecords>> getAcademicRecords() {
    final result = academicRecords;
    if (result == null) throw UnimplementedError();
    return Future.value(result);
  }

  @override
  Future<GatewayResult<ErkeOverview>> getErkeOverview() =>
      throw UnimplementedError();

  @override
  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview() {
    final result = physicalOverview;
    if (result == null) throw UnimplementedError();
    return Future.value(result);
  }

  @override
  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  }) =>
      throw UnimplementedError();
}

class _FakeAutomationGateway implements DeviceAutomationGateway {
  _FakeAutomationGateway(
    this.gateway, {
    required this.ensured,
    this.academicDatasets = const {},
    this.ensureFreshFailures = const [],
  });

  final PersonalDataGateway gateway;
  final EnsureFreshResult ensured;
  final Map<String, Map<String, dynamic>> academicDatasets;

  /// 依次在 ensureFresh 调用时抛出的异常；脚本耗尽后恢复成功。
  final List<DeviceAutomationException> ensureFreshFailures;
  int _ensureFreshCalls = 0;

  @override
  Future<FreshnessState> inspect(PersonalDataType type) async => ensured.after;

  @override
  Future<GatewayResult<Map<String, dynamic>>> readAcademicDataset(
    String dataset,
  ) async =>
      GatewayResult<Map<String, dynamic>>(
        status: GatewayStatus.available,
        source: PersonalDataSource.deviceEncryptedCache,
        data: academicDatasets[dataset] ?? <String, dynamic>{},
        fetchedAt: ensured.after.fetchedAt,
        expiresAt: ensured.after.expiresAt,
      );

  @override
  Future<RefreshResult> refreshAcademic() async =>
      const RefreshResult(performed: true);

  @override
  Future<RefreshResult> refreshAcademicSituation() async =>
      const RefreshResult(performed: true);

  @override
  Future<RefreshResult> refreshCreditRequirements() async =>
      const RefreshResult(performed: true);

  @override
  Future<RefreshResult> refreshSchedule() async =>
      const RefreshResult(performed: true);

  @override
  Future<RefreshResult> refreshErke({bool automationUpload = false}) async =>
      const RefreshResult(performed: true);

  @override
  Future<RefreshResult> refreshPhysical() async =>
      const RefreshResult(performed: true);

  @override
  Future<EnsureFreshResult> ensureFresh(
    PersonalDataType type, {
    required Duration maxAge,
    bool automationUpload = false,
  }) async {
    if (_ensureFreshCalls < ensureFreshFailures.length) {
      throw ensureFreshFailures[_ensureFreshCalls++];
    }
    _ensureFreshCalls += 1;
    return ensured;
  }

  @override
  Future<AcademicBundleEnsureResult> ensureFreshAcademicBundle({
    required Map<String, Duration> maxAges,
  }) async =>
      AcademicBundleEnsureResult(
        items: <String, EnsureFreshResult>{
          for (final key in maxAges.keys) key: ensured,
        },
      );

  @override
  Future<GatewayResult<T>> read<T>(DeviceDataQuery<T> query) => query(gateway);

  @override
  Future<void> close() async {}
}
