import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../campus_data/storage/academic_cache_store.dart';
import '../campus_data/erke/erke_repository.dart';
import '../campus_data/storage/erke_cache_store.dart';
import '../ai_runtime/personal_data/gateway/gateway_result.dart';
import '../../providers/auth_provider.dart';
import '../../providers/edu_provider.dart';
import '../../services/physical_credential_store.dart';
import '../../services/push_settings_service.dart';
import '../../services/webvpn_service.dart';
import '../../utils/app_feedback.dart';
import '../../utils/app_navigator.dart';
import '../ai_runtime/personal_data/gateway/personal_account_context.dart';
import '../ai_runtime/personal_data/gateway/personal_data_gateway_impl.dart';
import '../physical/physical_data_sync_service.dart';
import '../personal_data_sync/personal_data_sync_coordinator.dart';
import '../personal_data_sync/personal_data_sync_result.dart';
import 'device_credential_prompt_sheet.dart';
import 'device_credential_store.dart';
import 'device_job_client.dart';
import 'device_job_models.dart';
import 'device_job_permission_sheet.dart';
import 'device_automation_gateway.dart';
import 'device_tool_worker.dart';

/// 将设备 Worker 绑定到当前 Flutter 账号。账号或教务来源变化时，旧上下文不会继续回传结果。
class DeviceToolBridgeHost extends StatefulWidget {
  const DeviceToolBridgeHost({super.key, required this.child});

  final Widget child;

  @override
  State<DeviceToolBridgeHost> createState() => _DeviceToolBridgeHostState();
}

class _DeviceToolBridgeHostState extends State<DeviceToolBridgeHost>
    with WidgetsBindingObserver {
  late final AuthProvider _auth;
  late final EduProvider _edu;
  late final DeviceToolWorker _worker;
  final DeviceCredentialStore _credentialStore = DeviceCredentialStore();
  final PhysicalCredentialStore _physicalCredentialStore =
      PhysicalCredentialStore();
  DeviceErkeCredentials? _sessionErkeCredentials;
  String? _sessionPhysicalPassword;
  String? _sessionCredentialAccountId;
  bool _saveErkeCredentials = false;
  bool _savePhysicalCredential = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth = context.read<AuthProvider>();
    _edu = context.read<EduProvider>();
    _worker = DeviceToolWorker(
      client: DioDeviceJobClient(_auth.dio),
      installationIdProvider: PushSettingsService.installationId,
      contextResolver: _resolveContext,
      permissionResolver: _requestPermission,
    );
    _auth.addListener(_scheduleSync);
    _edu.addListener(_scheduleSync);
    DeviceToolBridge.install(_worker);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPending());
  }

  @override
  void dispose() {
    DeviceToolBridge.uninstall(_worker);
    _auth.removeListener(_scheduleSync);
    _edu.removeListener(_scheduleSync);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncPending();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPending());
  }

  Future<void> _syncPending() async {
    if (!mounted) return;
    try {
      await _worker.syncPending();
    } catch (_) {
      // 断网和服务端暂不可用保留任务，下一次前台恢复或推送会再次补拉。
    }
  }

  Future<DeviceToolWorkerContext?> _resolveContext() async {
    final appUserId = _auth.user?.id.toString().trim() ?? '';
    final sourceAccountId = _sourceAccountId();
    if (!_auth.isLoggedIn || appUserId.isEmpty || sourceAccountId.isEmpty) {
      return null;
    }
    return DeviceToolWorkerContext(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      createGateway: () => PersonalDataGatewayFactory().create(
        PersonalAccountContext(
          appUserId: appUserId,
          sourceAccountId: sourceAccountId,
        ),
      ),
      createAutomationGateway: () => _createAutomationGateway(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      isCurrent: () async =>
          mounted &&
          _auth.isLoggedIn &&
          _auth.user?.id.toString() == appUserId &&
          _sourceAccountId() == sourceAccountId,
    );
  }

  DeviceAutomationGateway _createAutomationGateway({
    required String appUserId,
    required String sourceAccountId,
  }) {
    final reader = PersonalDataGatewayFactory().create(
      PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
    );
    final sync = EduProviderPersonalAcademicSyncGateway(_edu);
    return PersonalDataDeviceAutomationGateway(
      reader: reader,
      refreshAcademic: () async => _toRefreshResult(
        await sync.syncGrades(),
      ),
      refreshAcademicSituation: () async => _toRefreshResult(
        await sync.syncAcademicSituation(),
      ),
      refreshCreditRequirements: () async => _toRefreshResult(
        await sync.syncCreditRequirements(),
      ),
      refreshSchedule: () async => _toRefreshResult(
        await sync.syncSchedule(),
      ),
      refreshErke: () => _refreshErke(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      refreshPhysical: () => _refreshPhysical(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
      readAcademicDataset: (dataset) => _readAcademicDataset(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
        dataset: dataset,
      ),
    );
  }

  Future<GatewayResult<Map<String, dynamic>>> _readAcademicDataset({
    required String appUserId,
    required String sourceAccountId,
    required String dataset,
  }) async {
    final store = AcademicCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
    );
    try {
      final snapshot = await store.readSnapshot();
      if (snapshot == null) {
        return GatewayResult<Map<String, dynamic>>(
          status: GatewayStatus.missing,
          source: PersonalDataSource.none,
        );
      }
      final now = DateTime.now().toUtc();
      final data = switch (dataset) {
        'academic_situation' => snapshot.situation == null
            ? null
            : _academicSituationData(snapshot.situation!.data),
        'credit_requirements' => snapshot.creditRequirements == null
            ? null
            : _creditRequirementsData(snapshot.creditRequirements!),
        _ => null,
      };
      if (data == null) {
        return GatewayResult<Map<String, dynamic>>(
          status: GatewayStatus.missing,
          source: PersonalDataSource.none,
        );
      }
      final fetchedAt = switch (dataset) {
        'academic_situation' => snapshot.situation!.fetchedAt,
        'credit_requirements' => snapshot.creditRequirementsFetchedAt,
        _ => snapshot.fetchedAt,
      };
      if (fetchedAt == null) {
        return GatewayResult<Map<String, dynamic>>(
          data: data,
          status: GatewayStatus.stale,
          source: PersonalDataSource.deviceEncryptedCache,
          isStale: true,
          warnings: const <String>['学分要求缺少独立更新时间，需要重新获取'],
        );
      }
      final ttl = dataset == 'academic_situation'
          ? const Duration(hours: 6)
          : const Duration(days: 1);
      final expiresAt = fetchedAt.add(ttl);
      // snapshot.isStale 是旧的全局快照标记，不能让成绩过期连带判定
      // 学业情况或学分要求过期；bundle 的三个数据集各自按 TTL 判断。
      final stale = !expiresAt.isAfter(now);
      return GatewayResult<Map<String, dynamic>>(
        data: data,
        status: stale ? GatewayStatus.stale : GatewayStatus.available,
        source: PersonalDataSource.localEncryptedVault,
        fetchedAt: fetchedAt,
        expiresAt: expiresAt,
        isStale: stale,
      );
    } finally {
      await store.close();
    }
  }

  static Map<String, dynamic> _academicSituationData(
    Map<String, dynamic> raw,
  ) {
    int integer(String key) => (raw[key] as num?)?.toInt() ?? 0;
    final gpa = (raw['all_gpa'] as num?)?.toDouble() ?? 0;
    return <String, dynamic>{
      'total_courses': integer('total_courses'),
      'passed_courses': integer('passed_courses'),
      'failed_courses': integer('failed_courses'),
      'in_progress_courses': integer('in_progress_courses'),
      'degree_total_courses': integer('degree_total_courses'),
      'degree_passed_courses': integer('degree_passed_courses'),
      'degree_failed_courses': integer('degree_failed_courses'),
      'degree_in_progress_courses': integer('degree_in_progress_courses'),
      'all_gpa': gpa,
    };
  }

  static Map<String, dynamic> _creditRequirementsData(
    Map<String, dynamic> raw,
  ) {
    final modules = (raw['modules'] as List?)?.whereType<Map>() ??
        const Iterable<Map>.empty();
    double sum(String key) => modules.fold<double>(0, (total, item) {
          final value = item[key];
          return total + (value is num ? value.toDouble() : 0);
        });
    final required = sum('required_credits');
    final earned = sum('earned_credits');
    final gap = (required - earned).clamp(0, double.infinity).toDouble();
    return <String, dynamic>{
      'required_credits': required,
      'earned_credits': earned,
      'completed_credits': earned,
      'remaining_credits': gap,
      'credit_gap': gap,
      'module_count': modules.length,
    };
  }

  static RefreshResult _toRefreshResult(PersonalSyncItemResult result) {
    final code = switch (result.failureReason) {
      PersonalSyncFailureReason.eduSessionExpired => 'edu_session_expired',
      PersonalSyncFailureReason.authorizationRequired =>
        'authorization_required',
      PersonalSyncFailureReason.credentialUnavailable =>
        'credential_unavailable',
      PersonalSyncFailureReason.networkUnavailable => 'network_unavailable',
      PersonalSyncFailureReason.refreshIncomplete => 'refresh_incomplete',
      PersonalSyncFailureReason.localStorageFailed => 'local_storage_failed',
      PersonalSyncFailureReason.unknown => 'device_refresh_failed',
      null => null,
    };
    return RefreshResult(
      // usingOldCache / partial success 只能说明同步流程保留了旧数据，
      // 不能作为 ensure_fresh 的远端刷新证据。
      performed:
          result.status == PersonalSyncItemStatus.success && !result.isPartial,
      message:
          result.status == PersonalSyncItemStatus.success && !result.isPartial
              ? null
              : result.message ?? '设备刷新未完成，仍使用旧缓存',
      errorCode: code,
    );
  }

  Future<DeviceToolPermissionDecision> _requestPermission(
      DeviceToolJob job) async {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return DeviceToolPermissionDecision.defer;
    }
    if (job.status != 'waiting_user') {
      // 这类 Job 已经通过服务端的 ask / always / never 决策；再次弹窗会
      // 造成双重授权。只有显式 waiting_user 才由设备侧完成一次确认。
      return await _prepareCredentials(job)
          ? DeviceToolPermissionDecision.allow
          : DeviceToolPermissionDecision.deny;
    }
    // 任务状态为 waiting_user 时才会走到这里；pending / pushed 已经在
    // 服务端完成 ask / always / never 合并，避免再次弹出同一授权。
    final dialogContext = _dialogContext;
    if (dialogContext == null) return DeviceToolPermissionDecision.defer;
    final allowed = await DeviceJobPermissionSheet.request(dialogContext, job);
    if (!allowed) return DeviceToolPermissionDecision.deny;
    return await _prepareCredentials(job)
        ? DeviceToolPermissionDecision.allow
        : DeviceToolPermissionDecision.deny;
  }

  BuildContext? get _dialogContext =>
      appNavigatorKey.currentState?.overlay?.context;

  String _sourceAccountId() {
    final eduStudentId = _edu.studentId.trim();
    if (eduStudentId.isNotEmpty) return eduStudentId;
    final boundStudentId = _auth.user?.eduStudentId.trim() ?? '';
    if (boundStudentId.isNotEmpty) return boundStudentId;
    return _auth.user?.studentId.trim() ?? '';
  }

  Future<bool> _prepareCredentials(DeviceToolJob job) async {
    if (!job.toolName.contains('.ensure_fresh_')) return true;
    final dialogContext = _dialogContext;
    if (dialogContext == null || !mounted) return false;
    final sourceAccountId = _sourceAccountId();
    if (sourceAccountId.isEmpty) return false;
    _resetSessionCredentialsIfAccountChanged(sourceAccountId);

    if (job.toolName.startsWith('device.erke.')) {
      _sessionErkeCredentials ??=
          await _credentialStore.readErke(sourceAccountId);
      if (_sessionErkeCredentials != null) return true;
      final currentContext = _dialogContext;
      if (currentContext == null || !currentContext.mounted) return false;
      final input = await DeviceCredentialPromptSheet.request(
        currentContext,
        kind: DeviceCredentialKind.erke,
        sourceAccountId: sourceAccountId,
      );
      if (input == null) return false;
      _sessionErkeCredentials = DeviceErkeCredentials(
        casPassword: input.password,
        erkePassword: input.secondaryPassword,
      );
      _saveErkeCredentials = input.saveOnDevice;
      return true;
    }

    if (job.toolName.startsWith('device.physical.')) {
      _sessionPhysicalPassword ??=
          await _physicalCredentialStore.read(sourceAccountId);
      if (_sessionPhysicalPassword?.isNotEmpty == true) return true;
      final currentContext = _dialogContext;
      if (currentContext == null || !currentContext.mounted) return false;
      final input = await DeviceCredentialPromptSheet.request(
        currentContext,
        kind: DeviceCredentialKind.physical,
        sourceAccountId: sourceAccountId,
      );
      if (input == null) return false;
      _sessionPhysicalPassword = input.password;
      _savePhysicalCredential = input.saveOnDevice;
      return true;
    }

    await _edu.refreshStatus();
    if (!mounted || _sourceAccountId() != sourceAccountId) return false;
    if (_edu.isAuthorized && _edu.sessionState == 'active') return true;
    final currentContext = _dialogContext;
    if (currentContext == null || !currentContext.mounted) return false;
    final input = await DeviceCredentialPromptSheet.request(
      currentContext,
      kind: DeviceCredentialKind.education,
      sourceAccountId: sourceAccountId,
    );
    if (input == null) return false;
    final bound = await _edu.bind(
      sourceAccountId,
      input.password,
      eduDataConsentAccepted: true,
    );
    final feedbackContext = _dialogContext;
    if (!bound && feedbackContext != null && feedbackContext.mounted) {
      AppFeedback.error(
        _edu.errorMessage ?? '教务验证失败，请检查密码后重试',
        context: feedbackContext,
      );
    }
    return bound;
  }

  void _resetSessionCredentialsIfAccountChanged(String sourceAccountId) {
    if (_sessionCredentialAccountId == sourceAccountId) return;
    _sessionCredentialAccountId = sourceAccountId;
    _sessionErkeCredentials = null;
    _sessionPhysicalPassword = null;
    _saveErkeCredentials = false;
    _savePhysicalCredential = false;
  }

  Future<RefreshResult> _refreshErke({
    required String appUserId,
    required String sourceAccountId,
  }) async {
    final credentials = _sessionErkeCredentials ??
        await _credentialStore.readErke(sourceAccountId);
    if (credentials == null) {
      return const RefreshResult(
        performed: false,
        message: '二课密码尚未填写',
        errorCode: 'credential_unavailable',
      );
    }
    final vpn = WebVpnService();
    final repository = ErkeRepository(
      vpnService: vpn,
      cacheStore: ErkeCacheStore(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
    );
    try {
      final result = await ErkeRepositoryPersonalSyncGateway(
        repository: repository,
        requestCredentials: () async => PersonalErkeCredentials(
          studentId: sourceAccountId,
          casPassword: credentials.casPassword,
          erkePassword: credentials.erkePassword,
        ),
      ).syncErke();
      if (result.status == PersonalSyncItemStatus.success) {
        if (_saveErkeCredentials) {
          await _credentialStore.writeErke(sourceAccountId, credentials);
          _saveErkeCredentials = false;
        }
        return const RefreshResult(performed: true);
      }
      _sessionErkeCredentials = null;
      await _credentialStore.deleteErke(sourceAccountId);
      return RefreshResult(
        performed: false,
        message: result.message ?? '二课更新失败，请重新输入密码',
        errorCode: 'credential_unavailable',
      );
    } finally {
      vpn.dispose();
    }
  }

  Future<RefreshResult> _refreshPhysical({
    required String appUserId,
    required String sourceAccountId,
  }) async {
    final password = _sessionPhysicalPassword ??
        await _physicalCredentialStore.read(sourceAccountId);
    if (password == null || password.isEmpty) {
      return const RefreshResult(
        performed: false,
        message: '体测密码尚未填写',
        errorCode: 'credential_unavailable',
      );
    }
    final service = PhysicalDataSyncService();
    try {
      final result = await service.syncLatest(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
        password: password,
      );
      if (result.success) {
        if (_savePhysicalCredential) {
          await _physicalCredentialStore.write(sourceAccountId, password);
          _savePhysicalCredential = false;
        }
        return const RefreshResult(performed: true);
      }
      if (result.errorCode == 'physical_credential_invalid') {
        _sessionPhysicalPassword = null;
        await _physicalCredentialStore.delete(sourceAccountId);
      }
      return RefreshResult(
        performed: false,
        message: result.errorCode == 'network_unavailable'
            ? '体测系统网络不可用'
            : '体测更新失败，请重新输入密码',
        errorCode: result.errorCode,
      );
    } finally {
      service.close();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
