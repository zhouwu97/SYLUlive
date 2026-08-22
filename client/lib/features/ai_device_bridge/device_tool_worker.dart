import '../ai_runtime/personal_data/gateway/personal_data_gateway.dart';

import 'device_job_client.dart';
import 'device_automation_gateway.dart';
import 'device_job_models.dart';
import 'device_tool_registry.dart';

class DeviceToolWorkerContext {
  const DeviceToolWorkerContext({
    required this.appUserId,
    required this.sourceAccountId,
    required this.createGateway,
    required this.isCurrent,
    this.createAutomationGateway,
  });

  final String appUserId;
  final String sourceAccountId;
  final PersonalDataGateway Function() createGateway;
  final Future<bool> Function() isCurrent;
  final DeviceAutomationGateway Function()? createAutomationGateway;
}

typedef DeviceToolContextResolver = Future<DeviceToolWorkerContext?> Function();

enum DeviceToolPermissionDecision { allow, deny, defer }

typedef DeviceToolPermissionResolver = Future<DeviceToolPermissionDecision>
    Function(DeviceToolJob job);

/// 设备侧轮询和推送入口。只在当前账号上下文仍有效时读取 AES-GCM 本地缓存。
class DeviceToolWorker {
  static const bridgeProtocolVersion = 2;
  static const clientVersion = '1.0.0';
  DeviceToolWorker({
    required DeviceJobApi client,
    required Future<String> Function() installationIdProvider,
    required DeviceToolContextResolver contextResolver,
    DeviceToolPermissionResolver? permissionResolver,
    DeviceToolRegistry? registry,
  })  : _client = client,
        _installationIdProvider = installationIdProvider,
        _contextResolver = contextResolver,
        _permissionResolver = permissionResolver,
        _registry = registry ?? DeviceToolRegistry();

  final DeviceJobApi _client;
  final Future<String> Function() _installationIdProvider;
  final DeviceToolContextResolver _contextResolver;
  final DeviceToolPermissionResolver? _permissionResolver;
  final DeviceToolRegistry _registry;

  Future<void>? _syncing;

  Future<void> syncPending() {
    final active = _syncing;
    if (active != null) return active;
    final future = _syncAll();
    _syncing = future;
    future.whenComplete(() {
      if (identical(_syncing, future)) _syncing = null;
    });
    return future;
  }

  /// 推送正文只允许传入任务 ID；实际参数仍通过 JWT 拉取。
  Future<void> handlePush(String jobId) async {
    if (!_isValidJobId(jobId)) return;
    final context = await _contextResolver();
    if (context == null || !await context.isCurrent()) return;
    final installationId = await _installationIdProvider();
    await _register(installationId);
    try {
      final job = await _client.get(installationId, jobId);
      await _processJob(job, installationId, context);
    } on DeviceJobApiException catch (error) {
      // 已过期、已取消和账号切换后的任务无需在客户端重试。
      if (error.code != 'job_expired' &&
          error.code != 'device_job_not_found' &&
          error.code != 'device_not_registered') {
        rethrow;
      }
    }
  }

  Future<void> _syncAll() async {
    final context = await _contextResolver();
    if (context == null || !await context.isCurrent()) return;
    final installationId = await _installationIdProvider();
    await _register(installationId);
    final jobs = await _client.pending(installationId);
    for (final job in jobs) {
      if (!await context.isCurrent()) return;
      await _processJob(job, installationId, context);
    }
  }

  Future<void> _register(String installationId) {
    return _client.register(
      installationId: installationId,
      toolNames: DeviceToolRegistry.supportedToolNames.toList(growable: false),
      bridgeProtocolVersion: bridgeProtocolVersion,
      clientVersion: clientVersion,
    );
  }

  Future<void> _processJob(
    DeviceToolJob job,
    String installationId,
    DeviceToolWorkerContext context,
  ) async {
    if ((job.status != 'pending' &&
            job.status != 'pushed' &&
            job.status != 'waiting_user') ||
        job.expiresAt.isBefore(DateTime.now().toUtc()) ||
        !DeviceToolRegistry.supportedToolNames.contains(job.toolName) ||
        !await context.isCurrent()) {
      return;
    }
    // 服务端在创建任务前已经合并 ask / always / never。只有显式进入
    // waiting_user 的任务才需要设备侧展示一次确认，避免“服务端问一次、手机再问一次”。
    final resolver = _permissionResolver;
    var decision = DeviceToolPermissionDecision.allow;
    if (job.status == 'waiting_user') {
      if (resolver == null) return;
      decision = await resolver(job);
      if (!await context.isCurrent()) return;
      if (decision == DeviceToolPermissionDecision.defer) return;
    }
    final claimed =
        await _client.claim(installationId, job.id, job.stateVersion);
    if (decision == DeviceToolPermissionDecision.deny) {
      await _client.fail(
        installationId,
        claimed.id,
        claimed.stateVersion,
        'permission_denied',
      );
      return;
    }

    final automation = context.createAutomationGateway?.call();
    final gateway = automation == null ? context.createGateway() : null;
    try {
      final result = await _registry.execute(
        claimed,
        gateway,
        automationGateway: automation,
      );
      if (!await context.isCurrent()) return;
      await _client.complete(
        installationId,
        claimed.id,
        claimed.stateVersion,
        result.value,
      );
    } on DeviceToolExecutionException catch (error) {
      if (await context.isCurrent()) {
        await _client.fail(
          installationId,
          claimed.id,
          claimed.stateVersion,
          error.code,
        );
      }
    } catch (_) {
      if (await context.isCurrent()) {
        await _client.fail(
          installationId,
          claimed.id,
          claimed.stateVersion,
          'device_tool_failed',
        );
      }
    } finally {
      if (automation != null) {
        await automation.close();
      } else {
        await gateway?.close();
      }
    }
  }

  static bool _isValidJobId(String value) =>
      RegExp(r'^[0-9a-fA-F-]{1,36}$').hasMatch(value);
}

/// 推送回调与启动补拉共享的当前 Worker 引用。离开账号上下文时必须卸载。
class DeviceToolBridge {
  DeviceToolBridge._();

  static DeviceToolWorker? _activeWorker;

  static void install(DeviceToolWorker worker) {
    _activeWorker = worker;
  }

  static void uninstall(DeviceToolWorker worker) {
    if (identical(_activeWorker, worker)) _activeWorker = null;
  }

  static Future<void> syncPending() =>
      _activeWorker?.syncPending() ?? Future.value();

  static Future<void> handlePush(String jobId) =>
      _activeWorker?.handlePush(jobId) ?? Future.value();
}
