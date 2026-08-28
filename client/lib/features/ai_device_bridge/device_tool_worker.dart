import 'package:flutter/foundation.dart';

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

enum DeviceBridgeStatus { connected, syncing, degraded, offline, unknown }

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
  bool _syncAgain = false;

  void _setBridgeStatus(DeviceBridgeStatus value) {
    DeviceToolBridge._setBridgeStatus(value);
  }

  Future<void> syncPending() {
    final active = _syncing;
    if (active != null) {
      _syncAgain = true;
      return active;
    }
    final future = _drainPending();
    _syncing = future;
    future.whenComplete(() {
      if (identical(_syncing, future)) _syncing = null;
    });
    return future;
  }

  Future<void> _drainPending() async {
    do {
      _syncAgain = false;
      await _syncAll();
    } while (_syncAgain);
  }

  /// 推送正文只允许传入任务 ID；实际参数仍通过 JWT 拉取。
  Future<void> handlePush(String jobId) async {
    if (!_isValidJobId(jobId)) return;
    _setBridgeStatus(DeviceBridgeStatus.syncing);
    try {
      final context = await _contextResolver();
      if (context == null) {
        _setBridgeStatus(DeviceBridgeStatus.offline);
        return;
      }
      if (!await context.isCurrent()) {
        _setBridgeStatus(DeviceBridgeStatus.offline);
        return;
      }
      final installationId = await _installationIdProvider();
      await _register(installationId);
      final job = await _client.get(installationId, jobId);
      await _processJob(job, installationId, context);
      _setBridgeStatus(DeviceBridgeStatus.connected);
    } on DeviceJobApiException catch (error) {
      // 已过期、已取消和账号切换后的任务无需在客户端重试；设备未注册则说明桥接状态已降级。
      if (error.code == 'job_expired' || error.code == 'device_job_not_found') {
        _setBridgeStatus(DeviceBridgeStatus.connected);
        return;
      }
      _setBridgeStatus(DeviceBridgeStatus.degraded);
      rethrow;
    } catch (_) {
      _setBridgeStatus(DeviceBridgeStatus.degraded);
      rethrow;
    }
  }

  Future<void> _syncAll() async {
    _setBridgeStatus(DeviceBridgeStatus.syncing);
    try {
      final context = await _contextResolver();
      if (context == null) {
        _setBridgeStatus(DeviceBridgeStatus.offline);
        return;
      }
      if (!await context.isCurrent()) {
        _setBridgeStatus(DeviceBridgeStatus.offline);
        return;
      }
      final installationId = await _installationIdProvider();
      await _register(installationId);
      final jobs = await _client.pending(installationId);
      for (final job in jobs) {
        if (!await context.isCurrent()) {
          _setBridgeStatus(DeviceBridgeStatus.offline);
          return;
        }
        await _processJob(job, installationId, context);
      }
      _setBridgeStatus(DeviceBridgeStatus.connected);
    } catch (_) {
      _setBridgeStatus(DeviceBridgeStatus.degraded);
      rethrow;
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
    final resolver = _permissionResolver;
    if (resolver == null) return;
    // resolver 可根据状态决定是否展示 UI。这样保留 Worker 的 fail-closed
    // 默认行为，同时允许现有服务端 pending 任务跳过重复确认。
    final decision = await resolver(job);
    if (!await context.isCurrent()) return;
    if (decision == DeviceToolPermissionDecision.defer) return;
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

    var current = claimed;
    current = await _reportProgress(
      installationId,
      current,
      'checking_freshness',
    );
    current = await _reportProgress(
      installationId,
      current,
      'request_received',
    );
    final refreshing = current.toolName.contains('.ensure_fresh_');
    if (refreshing) {
      current = await _reportProgress(
        installationId,
        current,
        'refresh_started',
      );
    }

    final automation = context.createAutomationGateway?.call();
    final gateway = automation == null ? context.createGateway() : null;
    try {
      final result = await _registry.execute(
        current,
        gateway,
        automationGateway: automation,
      );
      if (!await context.isCurrent()) return;
      if (refreshing) {
        current = await _reportProgress(
          installationId,
          current,
          'refresh_completed',
        );
      }
      current = await _reportProgress(
        installationId,
        current,
        'reading_result',
      );
      await _client.complete(
        installationId,
        current.id,
        current.stateVersion,
        result.value,
      );
    } on DeviceAutomationException catch (error) {
      // 凭据失败时，尝试本地重试一次：弹窗输入密码后重新执行
      if (error.code == 'credential_unavailable' && await context.isCurrent()) {
        final retryDecision = await resolver.call(job);
        if (retryDecision == DeviceToolPermissionDecision.allow &&
            await context.isCurrent()) {
          // 密码已更新，在同一个 claimed job 上重试
          try {
            final retryResult = await _registry.execute(
              current,
              gateway,
              automationGateway: automation,
            );
            if (!await context.isCurrent()) return;
            if (refreshing) {
              current = await _reportProgress(
                installationId,
                current,
                'refresh_completed',
              );
            }
            current = await _reportProgress(
              installationId,
              current,
              'reading_result',
            );
            await _client.complete(
              installationId,
              current.id,
              current.stateVersion,
              retryResult.value,
            );
            return;
          } on DeviceAutomationException catch (retryError) {
            // 重试失败，正常走 fail 流程
            if (await context.isCurrent()) {
              if (refreshing) {
                current = await _reportProgress(
                  installationId,
                  current,
                  'refresh_failed',
                );
              }
              await _client.fail(
                installationId,
                current.id,
                current.stateVersion,
                retryError.code,
              );
            }
            return;
          } on DeviceToolExecutionException catch (retryError) {
            if (await context.isCurrent()) {
              if (refreshing) {
                current = await _reportProgress(
                  installationId,
                  current,
                  'refresh_failed',
                );
              }
              await _client.fail(
                installationId,
                current.id,
                current.stateVersion,
                retryError.code,
              );
            }
            return;
          }
        }
      }

      if (await context.isCurrent()) {
        if (refreshing) {
          current = await _reportProgress(
            installationId,
            current,
            'refresh_failed',
          );
        }
        await _client.fail(
          installationId,
          current.id,
          current.stateVersion,
          error.code,
        );
      }
    } on DeviceToolExecutionException catch (error) {
      if (await context.isCurrent()) {
        if (refreshing) {
          current = await _reportProgress(
            installationId,
            current,
            'refresh_failed',
          );
        }
        await _client.fail(
          installationId,
          current.id,
          current.stateVersion,
          error.code,
        );
      }
    } catch (_) {
      if (await context.isCurrent()) {
        if (refreshing) {
          current = await _reportProgress(
            installationId,
            current,
            'refresh_failed',
          );
        }
        await _client.fail(
          installationId,
          current.id,
          current.stateVersion,
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

  Future<DeviceToolJob> _reportProgress(
    String installationId,
    DeviceToolJob job,
    String stage,
  ) async {
    try {
      return await _client.progress(
        installationId,
        job.id,
        job.stateVersion,
        stage,
      );
    } on DeviceJobApiException {
      // 进度是可恢复的增量，不能因为旧客户端/网络抖动阻断真实工具执行。
      return job;
    }
  }

  static bool _isValidJobId(String value) =>
      RegExp(r'^[0-9a-fA-F-]{1,36}$').hasMatch(value);
}

/// 推送回调与启动补拉共享的当前 Worker 引用。离开账号上下文时必须卸载。
class DeviceToolBridge {
  DeviceToolBridge._();

  static DeviceToolWorker? _activeWorker;
  static final ValueNotifier<DeviceBridgeStatus> statusNotifier =
      ValueNotifier<DeviceBridgeStatus>(DeviceBridgeStatus.unknown);

  static DeviceBridgeStatus get status => statusNotifier.value;

  static void install(DeviceToolWorker worker) {
    _activeWorker = worker;
    statusNotifier.value = DeviceBridgeStatus.unknown;
  }

  static void uninstall(DeviceToolWorker worker) {
    if (identical(_activeWorker, worker)) {
      _activeWorker = null;
      statusNotifier.value = DeviceBridgeStatus.offline;
    }
  }

  static Future<void> syncPending() =>
      _activeWorker?.syncPending() ?? Future.value();

  static Future<void> handlePush(String jobId) =>
      _activeWorker?.handlePush(jobId) ?? Future.value();

  static void _setBridgeStatus(DeviceBridgeStatus value) {
    statusNotifier.value = value;
  }
}
