import 'dart:async';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'platform/contracts/push_client.dart';
import 'platform/contracts/system_notification_client.dart';
import 'platform/contracts/external_navigator.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/post_provider.dart';
import 'providers/poll_provider.dart';
import 'providers/team_recruitment_provider.dart';
import 'providers/message_provider.dart';
import 'providers/edu_provider.dart';
import 'providers/course_schedule_provider.dart';
import 'providers/major_provider.dart';
import 'providers/teacher_provider.dart';
import 'providers/canteen_provider.dart';
import 'providers/canteen_discovery_provider.dart';
import 'providers/social_provider.dart';
import 'providers/water_section_provider.dart';
import 'providers/water_moderator_provider.dart';
import 'providers/water_moderation_provider.dart';
import 'providers/campus_calendar_provider.dart';
import 'providers/user_calendar_provider.dart';
import 'features/academic/application/academic_session_controller.dart';
import 'features/academic/data/academic_repository_impl.dart';
import 'features/academic/data/academic_server_access_guard.dart';
import 'features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'features/academic/data/datasource/legacy_server_data_source.dart';
import 'features/academic/domain/academic_repository.dart';
import 'models/user.dart';
import 'models/startup_destination.dart';
import 'screens/chat_detail_screen.dart';
import 'screens/post_detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/privacy_center_screen.dart';
import 'screens/exam_schedule_screen.dart';
import 'screens/edu_grade_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/team/team_recruitment_detail_screen.dart';
import 'services/course_reminder_service.dart';
import 'theme/app_theme.dart';
import 'config/api_constants.dart';
import 'utils/app_navigator.dart';
import 'utils/app_navigation.dart';
import 'utils/grade_screen_registry.dart';
import 'utils/private_message_notification.dart';
import 'utils/team_share_link.dart';
import 'utils/notification_open_target.dart';
import 'services/diagnostic_log_service.dart';
import 'services/diagnostic_dio_interceptor.dart';
import 'services/request_id.dart';
import 'services/root_page_state_service.dart';
import 'services/retry_interceptor.dart';
import 'services/app_resume_coordinator.dart';
import 'services/account_session_cleanup_coordinator.dart';
import 'services/campus_calendar_service.dart';
import 'services/user_calendar_service.dart';
import 'services/post_cache_service.dart';
import 'services/forbidden_recovery_router.dart';
import 'services/poll_service.dart';
import 'services/app_update_coordinator.dart';
import 'services/push_settings_service.dart';
import 'services/emoji_favorite_repository.dart';
import 'services/emoji_favorite_service.dart';
import 'features/ai_device_bridge/device_tool_bridge_host.dart';
import 'features/ai_device_bridge/device_tool_worker.dart';
import 'platform/platform_bootstrap.dart';
import 'platform/platform_capabilities.dart';
import 'widgets/app_update_gate.dart';
import 'widgets/app_crash_fallback.dart';
import 'widgets/global_background_wrapper.dart';
import 'widgets/startup_recovery_screen.dart';
import 'widgets/required_legal_consent_dialog.dart';
import 'platform/contracts/preferences_store.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

export 'widgets/global_background_wrapper.dart'
    show
        BackgroundWrapperState,
        GlobalBackgroundWrapper,
        PredictiveBackGate,
        backgroundWrapperKey;

String _hashError(
  String level,
  String source,
  String type,
  String summary,
  String detail,
) {
  final bytes = utf8.encode('$level$source$type$summary$detail');
  return md5.convert(bytes).toString();
}

class _FlutterErrorLogInfo {
  final String level;
  final String source;
  final String type;
  final String summary;
  final String detail;

  const _FlutterErrorLogInfo({
    required this.level,
    required this.source,
    required this.type,
    required this.summary,
    required this.detail,
  });
}

_FlutterErrorLogInfo _classifyFlutterError(FlutterErrorDetails details) {
  final exceptionText = details.exceptionAsString();
  final fullString = details.toString();

  final overflowMatch = RegExp(
    r'A RenderFlex overflowed by ([\d.]+) pixels on the (bottom|top|left|right)',
  ).firstMatch(exceptionText);

  if (overflowMatch != null) {
    final pixels = overflowMatch.group(1) ?? '?';
    final edge = overflowMatch.group(2) ?? '边缘';
    final edgeLabel = switch (edge) {
      'bottom' => '底部',
      'top' => '顶部',
      'left' => '左侧',
      'right' => '右侧',
      _ => edge,
    };

    final fileMatch = RegExp(
      r'file:///([^\n]+?):(\d+):(\d+)',
    ).firstMatch(fullString);

    final location = fileMatch == null
        ? '未识别到具体文件'
        : '${fileMatch.group(1)}:${fileMatch.group(2)}';

    return _FlutterErrorLogInfo(
      level: 'warning',
      source: '界面',
      type: '布局溢出',
      summary: '页面组件尺寸不足，内容向$edgeLabel溢出 ${pixels}px',
      detail: [
        '问题说明：某个 Column / Row 中的内容超过了父组件可用空间。',
        '影响范围：通常不会导致 App 崩溃，但会造成界面被挤出、黄黑条或日志刷屏。',
        '定位位置：$location',
        '修复建议：检查固定高度、padding、图标尺寸、文字字号；优先使用 Flexible / Expanded / FittedBox 让内容自适应。',
        '',
        '原始 Flutter 错误：',
        fullString,
      ].join('\n'),
    );
  }

  return _FlutterErrorLogInfo(
    level: 'error',
    source: 'Flutter',
    type: details.exception.runtimeType.toString(),
    summary: exceptionText,
    detail: fullString,
  );
}

final Map<String, int> _dedupTimes = {};
VoidCallback? _appRecoveryRetry;

void _safeRecord({
  required String level,
  required String source,
  required String type,
  required String summary,
  required String detail,
  required String dedupKey,
  required int dedupMs,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lastTime = _dedupTimes[dedupKey] ?? 0;

  if (now - lastTime < dedupMs) {
    return; // Deduplicate
  }
  _dedupTimes[dedupKey] = now;

  // Clean up old entries to prevent memory leak
  if (_dedupTimes.length > 100) {
    _dedupTimes.removeWhere((_, time) => now - time > 60 * 60 * 1000);
  }

  DiagnosticLogService.instance.record(
    level: level,
    source: source,
    type: type,
    summary: summary,
    detail: detail,
    eventCode: level == 'warning' ? 'app_warning' : 'uncaught_app_error',
    category: _diagnosticCategoryFor(source),
    operation: 'handle_error',
    result: 'failure',
    metadata: <String, Object?>{'exceptionType': type},
  );
}

String _diagnosticCategoryFor(String source) => switch (source) {
      '图片' || '网络' => 'network',
      '存储' || '缓存' => 'storage',
      '导航' || '深链' => 'navigation',
      '账号' => 'auth',
      '设备工具' => 'device',
      '教务' => 'edu',
      '消息' => 'message',
      '保活' || '后台' => 'background',
      _ => 'app',
    };

String _startupDiagnosticText(Object error, StackTrace stackTrace) {
  return [
    'SYLUlive 启动诊断',
    '时间：${DateTime.now().toIso8601String()}',
    '错误：$error',
    '',
    stackTrace.toString(),
  ].join('\n');
}

Future<void> _clearNonSensitiveStartupCache() async {
  Object? firstError;
  StackTrace? firstStackTrace;

  try {
    await PostCacheService.clearAllCache();
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }

  try {
    final preferences = await AppPreferencesStore.getInstance();
    await Future.wait([
      preferences.remove(RootPageStateStore.communityFeedModeKey),
      preferences.remove(RootPageStateStore.communityFeedScrollKey),
      preferences.remove(RootPageStateStore.lastPageKey),
    ]);
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }

  if (firstError != null) {
    Error.throwWithStackTrace(
        firstError, firstStackTrace ?? StackTrace.current);
  }
}

Future<void> _retryAppBootstrap() async {
  await appBootstrap();
}

Future<void> appBootstrap() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _appRecoveryRetry = null;
      // 在任何本地数据库或平台服务初始化前先挂载最小壳，确保失败时有可见 UI。
      runApp(
        const StartupRecoveryApp(child: StartupRecoveryScreen()),
      );
      await _initializeNativeNotificationOpenBridge();

      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);

        final exceptionText = details.exceptionAsString();

        if (exceptionText.contains('_ClientSocketException') &&
            details.library == 'image resource service') {
          final hostMatch = RegExp(
            r'address\s*=\s*([^\s,:]+)',
          ).firstMatch(exceptionText);
          final host = hostMatch?.group(1) ?? 'unknown';

          _safeRecord(
            level: 'warning',
            source: '图片',
            type: '图片加载失败',
            summary: '图片连接被中途断开',
            detail: exceptionText,
            dedupKey: 'image_error_$host',
            dedupMs: 10 * 60 * 1000, // 10 minutes
          );
          return;
        }

        final info = _classifyFlutterError(details);
        _safeRecord(
          level: info.level,
          source: info.source,
          type: info.type,
          summary: info.summary,
          detail: info.detail,
          dedupKey: _hashError(
            info.level,
            info.source,
            info.type,
            info.summary,
            info.detail,
          ),
          dedupMs: 2000,
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        final exceptionText = error.toString();
        final fullString = '$error\n\n$stack';

        _safeRecord(
          level: 'error',
          source: 'Flutter',
          type: error.runtimeType.toString(),
          summary: exceptionText,
          detail: fullString,
          dedupKey: _hashError(
            'error',
            'Flutter',
            error.runtimeType.toString(),
            exceptionText,
            fullString,
          ),
          dedupMs: 2000,
        );
        return true;
      };

      ErrorWidget.builder = (details) {
        final diagnosticId = _hashError(
          'error',
          'Flutter',
          details.exception.runtimeType.toString(),
          details.exceptionAsString(),
          details.toString(),
        );
        return AppCrashFallback(
          details: details,
          diagnosticId: diagnosticId,
          onRetry: _appRecoveryRetry,
        );
      };

      // 强制沉浸式（Edge-to-Edge），解决悬浮底栏下方的系统黑条空挡问题
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          statusBarColor: Colors.transparent,
        ),
      );

      try {
        await Hive.initFlutter();
      } catch (error, stackTrace) {
        await DiagnosticLogService.instance.recordError(
          source: '存储',
          type: 'Hive 初始化失败',
          summary: '本地数据库初始化失败',
          detail: '$error\n\n$stackTrace',
          eventCode: 'storage_hive_init_failed',
          category: 'storage',
          operation: 'initialize',
          result: 'failure',
        );
        runApp(
          StartupRecoveryApp(
            child: StartupRecoveryScreen(
              error: error,
              stackTrace: stackTrace,
              diagnosticText: _startupDiagnosticText(error, stackTrace),
              onRetry: _retryAppBootstrap,
              onClearNonSensitiveCache: () async {
                await _clearNonSensitiveStartupCache();
                await _retryAppBootstrap();
              },
            ),
          ),
        );
        return;
      }

      PushSettingsService.configureRemoteRegistration(setupPush);

      try {
        final deletedCount = await PostCacheService.clearLegacyCache();
        if (deletedCount > 0) {
          debugPrint('已清理 $deletedCount 条旧版帖子缓存');
        }
      } catch (e, stackTrace) {
        debugPrint('清理旧帖子缓存失败: $e');
        debugPrintStack(stackTrace: stackTrace);
        DiagnosticLogService.instance.record(
          level: 'warning',
          source: '存储',
          type: '缓存清理失败',
          summary: '旧版帖子缓存清理失败',
          detail: '$e\n\n$stackTrace',
          eventCode: 'storage_cache_cleanup_failed',
          category: 'storage',
          operation: 'cleanup',
          result: 'failure',
        );
      }

      _appRecoveryRetry = () => runApp(const MyApp());
      runApp(const MyApp());

      WidgetsBinding.instance.addPostFrameCallback((_) {
        PlatformBootstrap().initializeAfterFirstFrame(
          initializeAndroidServices: () async {
            await CourseReminderService.instance.initialize();
            await _ensurePrivateMessageNotificationsReady();
          },
        );
      });
    },
    (error, stack) {
      final exceptionText = error.toString();
      final fullString = '$error\n\n$stack';
      _safeRecord(
        level: 'error',
        source: 'Dart',
        type: error.runtimeType.toString(),
        summary: exceptionText,
        detail: fullString,
        dedupKey: _hashError(
          'error',
          'Dart',
          error.runtimeType.toString(),
          exceptionText,
          fullString,
        ),
        dedupMs: 2000,
      );
    },
  );
}

/// 极光推送初始化
final PushClient pushClient = PushClient.current();
final SystemNotificationClient systemNotificationClient =
    SystemNotificationClient.current();
bool _privateMessageNotificationsReady = false;
const MethodChannel _privateMessageNotificationChannel = MethodChannel(
  'shenliyuan/private_message_notifications',
);
const MethodChannel _notificationOpenChannel = MethodChannel(
  'shenliyuan/notification_open',
);

// ── 移除 Flutter 侧 Alias 绑定状态追踪（统一由原生状态机管理） ──

/// 冷启动时通知数据临时存放（navigator 未就绪前）
final PendingPrivateMessageOpen _pendingPrivateMessageOpen =
    PendingPrivateMessageOpen();

/// 冷启动时普通通知数据临时存放
final PendingNotificationOpen _pendingNotificationOpen =
    PendingNotificationOpen();

bool _jpushHandlersRegistered = false;
bool _pendingNotificationProcessScheduled = false;
bool _nativeNotificationOpenBridgeReady = false;
bool _checkingNativeNotificationOpen = false;

Future<void> _initializeNativeNotificationOpenBridge() async {
  if (_nativeNotificationOpenBridgeReady) return;
  _nativeNotificationOpenBridgeReady = true;

  _notificationOpenChannel.setMethodCallHandler((call) async {
    if (call.method != 'onNotificationOpen') {
      throw MissingPluginException('未知通知点击方法: ${call.method}');
    }

    final raw = call.arguments;
    if (raw is String && raw.isNotEmpty) {
      await _handleNativeNotificationOpen(raw);
    }
    return true;
  });

  await _checkNativeNotificationOpen();
}

Future<void> _checkNativeNotificationOpen() async {
  if (_checkingNativeNotificationOpen) return;
  _checkingNativeNotificationOpen = true;
  try {
    final raw = await _notificationOpenChannel
        .invokeMethod<String>('getPendingNotificationOpen');
    if (raw != null && raw.isNotEmpty) {
      await _handleNativeNotificationOpen(raw);
    }
  } on MissingPluginException {
    // 非 Android 平台没有原生通知点击桥。
  } catch (e) {
    debugPrint('读取原生待处理通知失败: $e');
  } finally {
    _checkingNativeNotificationOpen = false;
  }
}

Future<void> _handleNativeNotificationOpen(String raw) async {
  final event = NativeNotificationOpen.parse(raw);
  if (event == null) {
    debugPrint('忽略格式无效的原生通知点击事件');
    return;
  }
  if (event.isExpired(DateTime.now())) {
    debugPrint('忽略已过期的原生通知点击: ${event.id}');
    await _ackNativeNotificationOpen(event.id);
    return;
  }

  final payload = event.payloadWithTrackingId();
  final extras = extractJPushExtras(payload);
  final recipientUserId = intFromNotificationExtra(
    extras[notificationRecipientUserIdKey],
  );
  final accountDecision = _notificationAccountDecision(recipientUserId);
  if (accountDecision == NotificationAccountDecision.waitForAuthentication) {
    return;
  }
  if (accountDecision == NotificationAccountDecision.reject) {
    debugPrint('丢弃账号归属不匹配的原生通知点击: recipient=$recipientUserId');
    await _ackNativeNotificationOpen(event.id);
    return;
  }

  final type = extras['type']?.toString();

  switch (type) {
    case 'private_message':
      final target = privateMessageTargetFromLocalPayload(jsonEncode(payload));
      if (target == null) {
        await _ackNativeNotificationOpen(event.id);
        return;
      }
      await _clearPrivateMessageNotifications(target.conversationId);
      _openPrivateMessage(target);
      return;
    case 'reply':
      final target = NotificationOpenTarget.parse(payload);
      if (target == null) {
        await _ackNativeNotificationOpen(event.id);
        return;
      }
      _storeOrOpenNotificationTarget(target);
      return;
    default:
      debugPrint('忽略未知原生通知点击: type=$type');
      await _ackNativeNotificationOpen(event.id);
  }
}

Future<void> _ackNativeNotificationOpen(String? eventId) async {
  if (eventId == null || eventId.isEmpty) return;
  try {
    final acknowledged = await _notificationOpenChannel.invokeMethod<bool>(
          'ackNotificationOpen',
          {'id': eventId},
        ) ??
        false;
    if (acknowledged) {
      Future<void>.delayed(Duration.zero, _checkNativeNotificationOpen)
          .ignore();
    }
  } catch (e) {
    debugPrint('确认原生通知点击失败: $e');
  }
}

void _ensureJPushHandlersRegistered() {
  if (_jpushHandlersRegistered) return;
  _jpushHandlersRegistered = true;

  pushClient.setHandlers(
    onReceiveNotification: (Map<String, dynamic> message) async {
      if (await _handleDeviceToolJobNotification(message)) return;
      // 极光 SDK 已展示通知，不弹本地兜底，避免双通知
      await _handlePrivateMessageNotification(
        message,
        opened: false,
        showLocalFallback: false,
      );
    },
    onNotifyMessageUnShow: (Map<String, dynamic> message) async {
      if (await _handleDeviceToolJobNotification(message)) return;
      // 极光 SDK 未展示通知，需要 Flutter 本地兜底
      await _handlePrivateMessageNotification(
        message,
        opened: false,
        showLocalFallback: true,
      );
    },
    onOpenNotification: (Map<String, dynamic> message) async {
      debugPrint('点击通知原始数据: $message');

      if (await _handleDeviceToolJobNotification(message)) return;
      if (await _handleUpdateNotification(message)) return;
      if (await _handlePrivateMessageNotification(message, opened: true)) {
        return;
      }

      final target = NotificationOpenTarget.parse(message);

      if (target == null) {
        final extras = extractJPushExtras(message);
        debugPrint('忽略未知或无效通知: type=${extras['type']}');
        return;
      }

      _storeOrOpenNotificationTarget(target);
    },
  );
}

/// 设备工具推送体只识别 job_id；参数和个人数据必须由 Worker 使用 JWT 再次拉取。
Future<bool> _handleDeviceToolJobNotification(
  Map<String, dynamic> message,
) async {
  final extras = extractJPushExtras(message);
  if (extras['type'] != 'ai_device_job') return false;
  final jobId = extras['job_id'];
  if (jobId is String && RegExp(r'^[0-9a-fA-F-]{1,36}$').hasMatch(jobId)) {
    try {
      await DeviceToolBridge.handlePush(jobId);
    } catch (_) {
      // 设备离线时由前台启动和生命周期恢复补拉 pending 任务。
    }
  }
  return true;
}

NotificationOpenTarget? _lastOpenedNotificationTarget;
DateTime? _lastOpenedNotificationAt;

bool _isDuplicateNotificationOpen(
  NotificationOpenTarget target,
  DateTime now,
) {
  final previous = _lastOpenedNotificationTarget;
  final previousAt = _lastOpenedNotificationAt;

  if (previous == null || previousAt == null) return false;

  return previous.hasSameDestination(target) &&
      now.difference(previousAt) < const Duration(seconds: 2);
}

void _navigateToNotificationTarget(NotificationOpenTarget target) {
  final accountDecision = _notificationAccountDecision(target.recipientUserId);
  if (accountDecision == NotificationAccountDecision.waitForAuthentication) {
    _pendingNotificationOpen.store(target);
    return;
  }
  if (accountDecision == NotificationAccountDecision.reject) {
    debugPrint(
      '丢弃账号归属不匹配的延迟普通通知: recipient=${target.recipientUserId}',
    );
    _ackNativeNotificationOpen(target.nativeOpenId).ignore();
    return;
  }

  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    _pendingNotificationOpen.store(target);
    _schedulePendingNotificationProcessing();
    return;
  }

  final now = DateTime.now();
  if (_isDuplicateNotificationOpen(target, now)) {
    debugPrint('忽略重复的通知跳转: ${target.type}');
    _ackNativeNotificationOpen(target.nativeOpenId).ignore();
    return;
  }

  _lastOpenedNotificationTarget = target;
  _lastOpenedNotificationAt = now;

  navigator.popUntil((route) => route.isFirst);

  switch (target.type) {
    case NotificationOpenType.reply:
      final postId = target.postId;

      if (postId == null) {
        navigator.push(
          MaterialPageRoute(
            builder: (_) => const NotificationsScreen(),
          ),
        );
        _ackNativeNotificationOpen(target.nativeOpenId).ignore();
        return;
      }

      navigator.push(
        MaterialPageRoute(
          builder: (_) => PostDetailScreen(
            postId: postId,
            targetReplyId: target.replyId,
          ),
        ),
      );
      _ackNativeNotificationOpen(target.nativeOpenId).ignore();
      return;
  }
}

void _storeOrOpenNotificationTarget(NotificationOpenTarget target) {
  final accountDecision = _notificationAccountDecision(target.recipientUserId);
  if (accountDecision == NotificationAccountDecision.waitForAuthentication) {
    _pendingNotificationOpen.store(target);
    _schedulePendingNotificationProcessing();
    return;
  }
  if (accountDecision == NotificationAccountDecision.reject) {
    debugPrint(
      '丢弃账号归属不匹配的普通通知: recipient=${target.recipientUserId}',
    );
    _ackNativeNotificationOpen(target.nativeOpenId).ignore();
    return;
  }

  final navigator = appNavigatorKey.currentState;

  if (navigator != null) {
    _navigateToNotificationTarget(target);
    return;
  }

  _pendingNotificationOpen.store(target);
  _schedulePendingNotificationProcessing();
}

NotificationAccountDecision _notificationAccountDecision(
  int? recipientUserId,
) {
  final context = appNavigatorKey.currentContext;
  if (context == null) {
    return NotificationAccountDecision.waitForAuthentication;
  }
  final authProvider = context.read<AuthProvider>();
  if (authProvider.isLoggedIn &&
      !(authProvider.user?.legalConsentsActive ?? false)) {
    return NotificationAccountDecision.waitForAuthentication;
  }
  return notificationAccountDecision(
    authInitialized: authProvider.isInitialized,
    currentUserId: authProvider.isLoggedIn ? authProvider.user?.id : null,
    recipientUserId: recipientUserId,
  );
}

void _schedulePendingNotificationProcessing() {
  if (_pendingNotificationProcessScheduled) return;
  _pendingNotificationProcessScheduled = true;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    _pendingNotificationProcessScheduled = false;
    _processPendingNotificationOpen();
  });
}

void _processPendingNotificationOpen() {
  if (appNavigatorKey.currentState == null) return;

  final now = DateTime.now();
  final target = _pendingNotificationOpen.consume(now);
  if (target != null) {
    debugPrint('🔗 执行延迟普通通知跳转: ${target.type}');
    _navigateToNotificationTarget(target);
  }
}

Future<RemotePushEnableResult> setupPush(AuthProvider authProvider) async {
  if (!await PushSettingsService.isEnabled()) {
    debugPrint('推送未主动启用，跳过 PushClient 初始化');
    return const RemotePushEnableResult(
      permissionGranted: false,
      registrationSucceeded: false,
      message: '推送未开启',
    );
  }
  if (ApiConstants.jpushAppKey.isEmpty) {
    DiagnosticLogService.instance.record(
      level: 'error',
      source: '推送',
      type: 'JPush 配置缺失',
      summary: 'JPUSH_APP_KEY 为空，已跳过初始化',
      detail: '请通过 --dart-define=JPUSH_APP_KEY 注入或设置默认值',
    );
    return const RemotePushEnableResult(
      permissionGranted: false,
      registrationSucceeded: false,
      message: '推送配置缺失，设备注册失败，请稍后重试',
    );
  }

  _ensureJPushHandlersRegistered();

  try {
    await PushSettingsService.setNativePushOptIn(true);
  } catch (e) {
    debugPrint('同步原生推送开关失败: $e');
    return const RemotePushEnableResult(
      permissionGranted: true,
      registrationSucceeded: false,
      message: '推送设置已保存，原生推送初始化失败，请稍后重试',
    );
  }

  pushClient.setup(
    appKey: ApiConstants.jpushAppKey,
    channel: 'developer-default',
    production: const bool.fromEnvironment(
      'JPUSH_PRODUCTION',
      defaultValue: !kDebugMode,
    ),
    debug: kDebugMode,
  );

  final rid = (await pushClient.getRegistrationId())?.trim() ?? '';

  if (rid.isEmpty) {
    return const RemotePushEnableResult(
      permissionGranted: true,
      registrationSucceeded: false,
      message: '推送设置已保存，设备注册尚未完成',
    );
  }
  final result = await authProvider.updatePushSettings(
    enabled: true,
    installationId: await PushSettingsService.installationId(),
    registrationId: rid,
    noticeVersion: PushSettingsService.noticeVersion,
  );
  if (!result.success) {
    debugPrint('推送设置上传失败: ${result.errorMessage}');
    return const RemotePushEnableResult(
      permissionGranted: true,
      registrationSucceeded: false,
      message: '推送设置已保存，设备登记失败，请稍后重试',
    );
  }

  final userId = authProvider.user?.id;
  if (userId == null) {
    return const RemotePushEnableResult(
      permissionGranted: true,
      registrationSucceeded: true,
      message: '已开启远程消息推送',
    );
  }

  final userIdStr = userId.toString();

  // JPush 的 Alias 在 Android/iOS 都由同一个 Dart 适配器维护；原生通道
  // 仅作为旧 Android 状态协调兼容层，不能成为 iOS 登记的硬依赖。
  try {
    await pushClient.setAlias(userIdStr);
  } catch (e) {
    debugPrint('JPush Alias 设置失败: $e');
  }

  // 将 userId 同步给原生层，后续的 Alias 绑定与退避重试完全由原生层
  // KeepAliveForegroundService 的 reconcileAliasState 机制接管
  try {
    final aliasSynced =
        await _privateMessageNotificationChannel.invokeMethod<bool>(
              'syncAlias',
              {'userId': userIdStr},
            ) ??
            false;
    if (!aliasSynced) {
      return const RemotePushEnableResult(
        permissionGranted: true,
        registrationSucceeded: false,
        message: '推送设置已保存，设备绑定失败，请稍后重试',
      );
    }
  } catch (e) {
    debugPrint('同步 Alias 到原生层失败: $e');
    return const RemotePushEnableResult(
      permissionGranted: true,
      registrationSucceeded: false,
      message: '推送设置已保存，设备绑定失败，请稍后重试',
    );
  }
  return const RemotePushEnableResult(
    permissionGranted: true,
    registrationSucceeded: true,
    message: '已开启远程消息推送',
  );
}

Future<void>? _privateMessageNotificationsInitFuture;

Future<void> _ensurePrivateMessageNotificationsReady() {
  if (_privateMessageNotificationsReady) return Future.value();

  _privateMessageNotificationsInitFuture ??= () async {
    try {
      await systemNotificationClient.initialize(
        onNotificationTap: (payload) {
          if (payload.isEmpty) return;
          try {
            final target =
                privateMessageTargetFromLocalPayload(jsonEncode(payload));
            if (target != null) {
              _clearPrivateMessageNotifications(target.conversationId).ignore();
              _openPrivateMessage(target);
            }
          } catch (e) {
            debugPrint('解析私信本地通知 payload 失败: $e');
          }
        },
      );
      _privateMessageNotificationsReady = true;
    } finally {
      _privateMessageNotificationsInitFuture = null;
    }
  }();

  return _privateMessageNotificationsInitFuture!;
}

/// 已通过本地通知展示过的极光 msg_id，用于去重
final Set<String> _shownLocalMessageIds = {};

Future<bool> _handlePrivateMessageNotification(
  Map<String, dynamic> message, {
  required bool opened,
  bool showLocalFallback = false,
}) async {
  final extras = extractJPushExtras(message);
  if (extras['type']?.toString() != 'private_message') {
    return false;
  }

  final target = privateMessageTargetFromJPushMessage(message);
  if (target == null) {
    debugPrint('私信推送缺少 conversation_id 或 sender_id');
    return true;
  }

  if (_notificationAccountDecision(target.recipientUserId) !=
      NotificationAccountDecision.allow) {
    debugPrint(
      '跳过非当前账号的私信处理: recipient=${target.recipientUserId}',
    );
    return true;
  }

  if (opened) {
    await _clearPrivateMessageNotifications(target.conversationId);
    _openPrivateMessage(target);
    return true;
  }

  // 正在查看同一会话 → 不弹通知，只刷新消息
  final context = appNavigatorKey.currentContext;
  final provider = context?.read<MessageProvider>();

  final lifecycleState = WidgetsBinding.instance.lifecycleState;
  final isAppForeground = lifecycleState == AppLifecycleState.resumed;
  final currentConversationId = provider?.activeConversationId;

  // 后台收到通知时，完全交给 Android/极光处理。
  // 不清通知、不刷新当前会话、不标记已读。
  if (!isAppForeground) {
    debugPrint(
      '私信后台到达：保留系统通知 '
      'lifecycle=$lifecycleState '
      'current=$currentConversationId '
      'target=${target.conversationId}',
    );
    return true;
  }

  final isViewingTargetConversation =
      currentConversationId == target.conversationId;

  DiagnosticLogService.instance.record(
    level: 'info',
    source: 'JPush',
    type: '私信处理',
    summary: '判断是否拦截系统通知',
    detail: 'lifecycle=${lifecycleState?.name ?? "unknown"}\n'
        'currentConversation=$currentConversationId\n'
        'targetConversation=${target.conversationId}\n'
        'decision=${isViewingTargetConversation ? "clear_and_read" : "keep_notification_background"}',
  );

  if (isViewingTargetConversation) {
    // 是否已读由聊天页结合路由顶层状态和消息可见位置决定。
    await provider?.refreshMessages();
    return true;
  }

  // 极光未显示通知 → Flutter 本地兜底弹窗
  if (showLocalFallback) {
    await _showPrivateMessageLocalNotification(target, message);
  }

  // 刷新会话列表
  await provider?.loadConversations(silent: true);
  return true;
}

/// 当极光 SDK 未展示通知时（onNotifyMessageUnShow），由 Flutter 弹本地通知兜底
Future<void> _showPrivateMessageLocalNotification(
  PrivateMessageTarget target,
  Map<String, dynamic> message,
) async {
  if (!_privateMessageNotificationsReady) return;

  final msgId = extractJPushExtras(message)['msg_id']?.toString() ?? '';
  if (msgId.isNotEmpty && _shownLocalMessageIds.contains(msgId)) {
    debugPrint('跳过重复本地私信通知: msg_id=$msgId');
    return;
  }
  if (msgId.isNotEmpty) {
    _shownLocalMessageIds.add(msgId);
    // 防止 Set 无限增长
    if (_shownLocalMessageIds.length > 200) {
      _shownLocalMessageIds.clear();
    }
  }

  final title = target.displayName;
  final body = notificationContent(message);
  if (body.isEmpty) return;

  try {
    await systemNotificationClient.showNotification(
      id: target.conversationId,
      title: title,
      body: body,
      payload: {
        'conversation_id': target.conversationId,
        'sender_id': target.senderId,
        'sender_name': target.displayName,
        'sender_avatar': target.senderAvatar,
        'message_id': target.messageId,
        notificationRecipientUserIdKey: target.recipientUserId,
      },
    );
    debugPrint('✅ 本地私信通知已弹出: ${target.displayName}');
  } catch (e) {
    debugPrint('本地私信通知弹出失败: $e');
  }
}

Future<void> _clearPrivateMessageNotifications(int conversationId) async {
  try {
    await _privateMessageNotificationChannel.invokeMethod(
      'clearConversationNotifications',
      {'conversationId': conversationId},
    );
  } catch (e) {
    debugPrint('清理私信通知失败: $e');
  }
}

void _openPrivateMessage(PrivateMessageTarget target) {
  final accountDecision = _notificationAccountDecision(target.recipientUserId);
  if (accountDecision == NotificationAccountDecision.waitForAuthentication) {
    _pendingPrivateMessageOpen.store(target);
    return;
  }
  if (accountDecision == NotificationAccountDecision.reject) {
    debugPrint(
      '丢弃账号归属不匹配的私信通知: recipient=${target.recipientUserId}',
    );
    _ackNativeNotificationOpen(target.nativeOpenId).ignore();
    return;
  }

  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    _pendingPrivateMessageOpen.store(target);
    debugPrint(
      '📌 冷启动缓冲通知跳转: conv=${target.conversationId} sender=${target.senderId}',
    );
    return;
  }
  debugPrint('🚪 navigator已就绪，直接跳转');
  _navigateToPrivateMessage(target);
}

PrivateMessageTarget? _lastOpenedPrivateMessageTarget;
DateTime? _lastOpenedPrivateMessageAt;

bool _isDuplicatePrivateMessageOpen(
  PrivateMessageTarget target,
  DateTime now,
) {
  final previous = _lastOpenedPrivateMessageTarget;
  final previousAt = _lastOpenedPrivateMessageAt;
  if (previous == null || previousAt == null) return false;

  return previous.sameConversation(target) &&
      previous.messageId == target.messageId &&
      now.difference(previousAt) < const Duration(seconds: 2);
}

void _navigateToPrivateMessage(PrivateMessageTarget target) {
  final accountDecision = _notificationAccountDecision(target.recipientUserId);
  if (accountDecision == NotificationAccountDecision.waitForAuthentication) {
    _pendingPrivateMessageOpen.store(target);
    return;
  }
  if (accountDecision == NotificationAccountDecision.reject) {
    debugPrint(
      '丢弃账号归属不匹配的延迟私信通知: recipient=${target.recipientUserId}',
    );
    _ackNativeNotificationOpen(target.nativeOpenId).ignore();
    return;
  }

  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    debugPrint('❌ navigate: navigator is null');
    return;
  }
  final resolvedTarget = _resolvePrivateMessageTarget(target);
  final now = DateTime.now();
  if (_isDuplicatePrivateMessageOpen(resolvedTarget, now)) {
    debugPrint('忽略重复的私信通知跳转: ${resolvedTarget.conversationId}');
    _ackNativeNotificationOpen(resolvedTarget.nativeOpenId).ignore();
    return;
  }
  _lastOpenedPrivateMessageTarget = resolvedTarget;
  _lastOpenedPrivateMessageAt = now;
  debugPrint(
    '🧭 navigate: push conv=${resolvedTarget.conversationId} sender=${resolvedTarget.senderId}',
  );
  try {
    final context = appNavigatorKey.currentContext;
    final provider = context?.read<MessageProvider>();
    if (provider?.activeConversationId == resolvedTarget.conversationId) {
      final messageId = resolvedTarget.messageId;
      if (messageId != null) {
        unawaited(provider!.requestMessageFocus(messageId));
      } else {
        unawaited(provider?.refreshMessages() ?? Future<void>.value());
      }
      _ackNativeNotificationOpen(resolvedTarget.nativeOpenId).ignore();
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => ChatDetailScreen(
        conversationId: resolvedTarget.conversationId,
        initialMessageId: resolvedTarget.messageId,
        targetUser: User(
          id: resolvedTarget.senderId,
          studentId: '',
          nickname: resolvedTarget.displayName,
          avatar: resolvedTarget.senderAvatar,
          createdAt: DateTime.now(),
        ),
      ),
    );
    final replaceStandaloneChat = provider?.activeConversationId != null &&
        provider?.activeConversationEmbedded == false;
    if (replaceStandaloneChat) {
      navigator.pushReplacement(route);
      debugPrint('✅ navigate: replace 成功');
    } else {
      navigator.push(route);
      debugPrint('✅ navigate: push 成功');
    }
    _ackNativeNotificationOpen(resolvedTarget.nativeOpenId).ignore();
  } catch (e) {
    debugPrint('❌ navigate: push 失败 - $e');
  }
}

PrivateMessageTarget _resolvePrivateMessageTarget(PrivateMessageTarget target) {
  final context = appNavigatorKey.currentContext;
  final authProvider = context?.read<AuthProvider>();
  final messageProvider = context?.read<MessageProvider>();
  final currentUserId = authProvider?.user?.id;
  if (currentUserId == null || messageProvider == null) return target;

  for (final conversation in messageProvider.conversations) {
    if (conversation.id != target.conversationId) continue;
    final user = conversation.getOtherUser(currentUserId);
    if (user == null) break;
    return target.copyWith(
      senderName: user.nickname.isNotEmpty ? user.nickname : target.senderName,
      senderAvatar: user.avatar.isNotEmpty ? user.avatar : target.senderAvatar,
    );
  }
  return target;
}

void _processPendingPrivateMessageOpen() {
  final now = DateTime.now();
  _pendingPrivateMessageOpen.markReady(now);

  if (appNavigatorKey.currentState == null) {
    debugPrint('📌 等待 navigator 就绪后再处理私信通知');
    return;
  }

  final target = _pendingPrivateMessageOpen.consume(now);
  if (target != null) {
    debugPrint(
      '✅ 处理缓冲通知: conv=${target.conversationId} sender=${target.senderId}',
    );
    _navigateToPrivateMessage(target);
  }
}

Future<bool> _handleUpdateNotification(Map<String, dynamic> message) async {
  final extras = extractJPushExtras(message);
  if (extras['type']?.toString() != 'app_update') {
    return false;
  }

  final downloadUrl = extras['download_url']?.toString() ?? '';
  final uri = Uri.tryParse(downloadUrl);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
    debugPrint('更新推送缺少有效下载地址');
    return true;
  }

  try {
    final nav = ExternalNavigator.current();
    final launched = await nav.open(uri);
    if (!launched) {
      debugPrint('无法打开更新下载地址: $downloadUrl');
    }
  } catch (e) {
    debugPrint('打开更新下载地址失败: $e');
  }
  return true;
}

class SafeLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (kDebugMode) {
      debugPrint('[HTTP] -> ${options.method} ${options.uri.path}');
    }
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (kDebugMode) {
      final data = response.data;
      String summary = '';
      if (data is List) {
        summary = 'List(length=${data.length})';
      } else if (data is Map) {
        summary = 'Map(keys=${data.keys.take(10).join(',')})';
      } else if (data != null) {
        if (data is String) {
          summary = 'String(length=${data.length > 50 ? '>50' : data.length})';
        } else {
          summary = 'Data(type=${data.runtimeType})';
        }
      }
      debugPrint(
        '[HTTP] <- ${response.requestOptions.method} ${response.requestOptions.uri.path} ${response.statusCode} $summary',
      );
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (kDebugMode) {
      debugPrint(
        '[HTTP] <- ERROR ${err.requestOptions.method} ${err.requestOptions.uri.path} ${err.response?.statusCode} type=${err.type}',
      );
    }
    super.onError(err, handler);
  }
}

Dio? _sharedDio;

Dio getSharedDio() {
  if (_sharedDio == null) {
    final dio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.baseUrl,
        connectTimeout: ApiConstants.connectTimeout,
        receiveTimeout: ApiConstants.receiveTimeout,
        sendTimeout: ApiConstants.sendTimeout,
      ),
    );

    // 本机教务使用 JiaowuClient；共享 App Dio 上的旧教务服务器出口统一阻断。
    dio.interceptors.add(const AcademicServerAccessGuard());

    // 每个业务请求都带版本头；服务端开启最低支持版本限制后，426 会由根级
    // 更新门禁接管，而不是在任意业务页面弹出分散提示。
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final requestId = options.headers['X-Request-ID']?.toString().trim();
          options.headers['X-Request-ID'] =
              requestId == null || requestId.isEmpty
                  ? RequestId.newId()
                  : requestId;
          if (options.extra['skip_app_version_interceptor'] == true) {
            handler.next(options);
            return;
          }
          try {
            options.headers
                .addAll((await AppVersionHeaders.load()).toHeaders());
          } catch (error) {
            debugPrint('附加应用版本请求头失败: $error');
          }
          handler.next(options);
        },
        onError: (error, handler) {
          if (error.response?.statusCode == 426 &&
              error.requestOptions.extra['skip_app_version_interceptor'] !=
                  true) {
            appUpdateCoordinator.requireUpdateFromApi();
          }
          handler.next(error);
        },
      ),
    );
    dio.interceptors.add(SafeRetryInterceptor(dio));
    dio.interceptors.add(DiagnosticDioInterceptor());

    if (kDebugMode) {
      dio.interceptors.add(SafeLogInterceptor());
    }

    _sharedDio = dio;
  }
  return _sharedDio!;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dio = getSharedDio();

    return MultiProvider(
      providers: [
        Provider<AcademicRepository>(
          create: (_) => AcademicRepositoryImpl(
            local: JiaowuLocalDataSource(),
            legacy: LegacyServerDataSource(dio, networkEnabled: false),
            source: AcademicSourceKind.local,
          ),
          dispose: (_, repository) => repository.close(),
        ),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: appUpdateCoordinator),
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            dio,
            onForbiddenRecovery: _handleForbiddenRecovery,
          ),
        ),
        ChangeNotifierProxyProvider<AuthProvider, AcademicSessionController>(
          create: (context) => AcademicSessionController(
            repository: context.read<AcademicRepository>(),
          ),
          update: (_, auth, controller) =>
              controller!..syncAppUser(auth.user?.id.toString()),
        ),
        ChangeNotifierProxyProvider<AuthProvider, EmojiFavoriteService>(
          create: (_) {
            final service = EmojiFavoriteService(
              repository: EmojiFavoriteRepository(dio),
            );
            EmojiFavoriteService.configureSharedInstance(service);
            return service;
          },
          update: (_, auth, service) {
            final nextUserId = auth.user?.id.toString();
            service!.syncSessionUser(nextUserId);
            if (nextUserId != null) {
              unawaited(service.syncFromServer());
            }
            EmojiFavoriteService.configureSharedInstance(service);
            return service;
          },
        ),
        ChangeNotifierProvider(create: (_) {
          final postProvider = PostProvider(dio);
          // H1.5：登录/退出/切换账号时清除首页 Feed 缓存与状态，
          // 避免账号 A 的个性化首页缓存被账号 B 读到。
          AccountSessionCleanupCoordinator.instance.register(
            postProvider,
            () => postProvider.invalidateHomeFeedCaches(),
          );
          return postProvider;
        }),
        ChangeNotifierProxyProvider2<AuthProvider, PostProvider, PollProvider>(
          create: (_) => PollProvider(PollService(dio)),
          update: (_, auth, posts, polls) => polls!
            ..syncSessionUser(auth.user?.id)
            ..bindPostProvider(posts),
        ),
        ChangeNotifierProxyProvider<AuthProvider, TeamRecruitmentProvider>(
          create: (_) => TeamRecruitmentProvider(dio),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id),
        ),
        ChangeNotifierProxyProvider<AuthProvider, MessageProvider>(
          create: (_) => MessageProvider(dio),
          update: (_, auth, provider) => provider!
            ..syncSessionUser(auth.user?.id, auth.accountSessionEpoch),
        ),
        ChangeNotifierProxyProvider2<AuthProvider, AcademicSessionController,
            EduProvider>(
          create: (_) => EduProvider(dio),
          update: (_, auth, academic, provider) => provider!
            ..setAcademicSessionController(academic)
            ..syncSessionUser(auth.user?.id.toString()),
        ),
        ChangeNotifierProxyProvider2<AuthProvider, EduProvider,
            CourseScheduleProvider>(
          create: (context) => CourseScheduleProvider(
            dio,
            null,
            context.read<AcademicRepository>(),
            context.read<AcademicSessionController>(),
          ),
          update: (_, auth, edu, provider) => provider!
            ..syncSessionContext(
              auth.user?.id.toString(),
              edu.studentId,
            ),
        ),
        ChangeNotifierProxyProvider<AuthProvider, TeacherProvider>(
          create: (_) => TeacherProvider(dio),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id),
        ),
        ChangeNotifierProxyProvider<AuthProvider, MajorProvider>(
          create: (_) => MajorProvider(dio),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id),
        ),
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider(create: (_) => CanteenDiscoveryProvider(dio)),
        ChangeNotifierProxyProvider<AuthProvider, SocialProvider>(
          create: (_) => SocialProvider(dio),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id),
        ),
        ChangeNotifierProxyProvider<AuthProvider, WaterSectionProvider>(
          create: (_) => WaterSectionProvider(dio),
          update: (_, auth, provider) => provider!
            ..syncSessionUser(auth.user?.id, auth.accountSessionEpoch),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              CampusCalendarProvider(CampusCalendarService(dio))..load(),
        ),
        ChangeNotifierProxyProvider<AuthProvider, UserCalendarProvider>(
          create: (_) => UserCalendarProvider(UserCalendarService(dio)),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id, auth.sessionGeneration),
        ),
        ChangeNotifierProxyProvider<AuthProvider, WaterModeratorProvider>(
          create: (_) => WaterModeratorProvider(dio),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id),
        ),
        ChangeNotifierProxyProvider<AuthProvider, WaterModerationProvider>(
          create: (_) => WaterModerationProvider(dio),
          update: (_, auth, provider) =>
              provider!..syncSessionUser(auth.user?.id),
        ),
      ],
      child: const DeviceToolBridgeHost(
        child: _WidgetDeepLinkHandler(child: _AppContent()),
      ),
    );
  }
}

/// 小组件深度链接处理器
///
/// 点击 widget → MainActivity → MethodChannel → 通知 HomeScreen 切到课表 tab
/// 不 push 新路由，不盖住现有页面。
class _WidgetDeepLinkHandler extends StatefulWidget {
  final Widget child;
  const _WidgetDeepLinkHandler({required this.child});

  @override
  State<_WidgetDeepLinkHandler> createState() => _WidgetDeepLinkHandlerState();
}

class _WidgetDeepLinkHandlerState extends State<_WidgetDeepLinkHandler>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('shenliyuan/deeplink');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDeepLink());

    // 监听原生端主动推送的深度链接（瞬间响应，避免打断动画）
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final uri = call.arguments as String?;
        await _consumeDeepLink(uri);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppResumeCoordinator.instance.onLifecycleChanged(context, state);
    if (state == AppLifecycleState.resumed) {
      _checkDeepLink();
    }
  }

  Future<void> _checkDeepLink() async {
    try {
      final uri = await _channel.invokeMethod<String>('getPendingDeepLink');
      await _consumeDeepLink(uri);
    } catch (e) {
      debugPrint('深度链接检查失败: $e');
      DiagnosticLogService.instance.record(
        level: 'warning',
        source: '导航',
        type: '深链读取失败',
        summary: '无法读取待处理的应用链接',
        detail: e.toString(),
        eventCode: 'navigation_deep_link_read_failed',
        category: 'navigation',
        operation: 'read',
        result: 'failure',
      );
    }
  }

  Future<void> _consumeDeepLink(String? uri) async {
    if (uri == null || !mounted) return;
    final handled = await _handleDeepLinkUri(uri);
    if (!handled) {
      final parsed = Uri.tryParse(uri);
      DiagnosticLogService.instance.record(
        level: 'warning',
        source: '导航',
        type: '深链无法处理',
        summary: '应用链接格式无效或目标暂不可用',
        detail: 'scheme=${parsed?.scheme}\nhost=${parsed?.host}',
        eventCode: 'navigation_deep_link_unhandled',
        category: 'navigation',
        operation: 'open',
        result: 'failure',
        route: _safeDeepLinkRoute(parsed),
      );
      return;
    }
    try {
      await _channel.invokeMethod<void>('ackPendingDeepLink', {'link': uri});
    } catch (error) {
      debugPrint('深度链接确认失败: $error');
    }
  }

  Future<bool> _handleDeepLinkUri(String? uri) async {
    if (uri == null || !mounted) return false;
    if (appNavigatorKey.currentState == null) {
      DiagnosticLogService.instance.record(
        level: 'warning',
        source: '导航',
        type: 'Navigator 未就绪',
        summary: '应用链接将在导航器就绪后重试',
        detail: '',
        eventCode: 'navigation_not_ready',
        category: 'navigation',
        operation: 'open',
        result: 'retry',
        route: _safeDeepLinkRoute(Uri.tryParse(uri)),
      );
      return false;
    }
    if (uri == 'widget_timetable' ||
        uri == 'campus://timetable' ||
        uri.startsWith('sylulive://schedule')) {
      appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      widgetTabSwitch.value++;
      return true;
    }
    if (uri.startsWith('widget_exam') || uri.startsWith('sylulive://exam')) {
      appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      appNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const ExamScheduleScreen()),
      );
      return true;
    }
    if (uri.startsWith('sylulive://grades') || uri.startsWith('grade_update')) {
      return _openGradeDeepLink(uri);
    }
    final recruitmentId = TeamShareLink.parseRecruitmentId(uri);
    if (recruitmentId == null) return false;

    // 授权撤销或尚未登录时不得通过分享链接绕过会话门禁。
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn || !(auth.user?.legalConsentsActive ?? false)) {
      return true;
    }
    appNavigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) =>
            TeamRecruitmentDetailScreen(recruitmentId: recruitmentId),
      ),
    );
    return true;
  }

  Future<bool> _openGradeDeepLink(String raw) async {
    final parsed = Uri.tryParse(raw);
    final year = parsed?.queryParameters['year'];
    final semester = int.tryParse(parsed?.queryParameters['semester'] ?? '');
    if (year == null || semester == null) return false;

    if (await GradeScreenRegistry.trySwitch(year, semester)) {
      return true;
    }

    appNavigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => EduGradeScreen(
          initialYear: year,
          initialSemester: semester,
        ),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

String _safeDeepLinkRoute(Uri? uri) {
  if (uri == null) return '';
  final authority = uri.host.isEmpty ? '' : '//${uri.host}';
  return '${uri.scheme}:$authority${uri.path}';
}

void _handleForbiddenRecovery(ForbiddenRecoveryRoute route) {
  if (!route.requiresAdminUiShutdown) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (appNavigatorKey.currentState != null) {
      // 管理员权限撤回时退出当前管理操作，避免旧页面继续提交操作。
      appNavigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    scaffoldMessengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('账号权限已更新，管理员操作已关闭')),
    );
  });
}

/// 抽离 MaterialApp 构建，避免 Consumer 嵌套层级过深
class _AppContent extends StatelessWidget {
  const _AppContent();

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      title: '沈理校园',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.lightTheme.copyWith(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.android: themeProvider.predictiveBack
                ? const PredictiveBackPageTransitionsBuilder()
                : const FadeUpwardsPageTransitionsBuilder(),
          },
        ),
        // 简洁模式下把全局 Scaffold 底色统一为暖白，覆盖所有走主题默认底色的页面。
        // 自定义背景模式与暗色模式不受影响（null = 沿用 ColorScheme 默认）。
        scaffoldBackgroundColor: themeProvider.isCleanBackgroundMode
            ? kCleanWarmBackgroundLight
            : null,
      ),
      darkTheme: AppTheme.darkTheme.copyWith(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.android: themeProvider.predictiveBack
                ? const PredictiveBackPageTransitionsBuilder()
                : const FadeUpwardsPageTransitionsBuilder(),
          },
        ),
      ),
      themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      navigatorKey: appNavigatorKey,
      navigatorObservers: [appRouteObserver],
      scaffoldMessengerKey: scaffoldMessengerKey,
      builder: (context, child) => AppUpdateGate(
        navigatorKey: appNavigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/timetable': (context) => AppNavigation.buildTimetablePage(),
      },
      home: const PredictiveBackGate(
        child: GlobalBackgroundWrapper(child: AuthWrapper()),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

@visibleForTesting
class HomeInitialTabResolver {
  int? _initialTab;
  int? _cachedUserId;

  /// 解析 `lastPage` 深层类型（chat/post/notification）时要打底的根 tab。
  static const int homeTabs = 5;

  int resolve(
    ThemeProvider themeProvider, {
    int? userId,
    RestorablePageState? lastPage,
  }) {
    final mode = themeProvider.startupDestination;
    // 启动 tab 是一次性的会话决策；用户在当前会话中修改偏好，不应把
    // 已经展示的根页面悄悄切走。切换账号时再重新解析。
    if (_initialTab != null && _cachedUserId == userId) {
      return _initialTab!;
    }
    _cachedUserId = userId;
    return _initialTab = initialTabFor(mode, lastPage);
  }

  void reset() {
    _initialTab = null;
    _cachedUserId = null;
  }

  /// 从启动模式与上次页面推断打底 root tab 索引（纯函数，便于测试）。
  @visibleForTesting
  static int initialTabFor(
    StartupDestinationMode mode,
    RestorablePageState? lastPage,
  ) {
    return switch (mode) {
      StartupDestinationMode.timetable => 2,
      StartupDestinationMode.lastPage => _rootIndexFor(lastPage),
      _ => 0,
    };
  }

  static int _rootIndexFor(RestorablePageState? state) {
    if (state == null) return 0;
    final dynamic raw = switch (state.type) {
      RestorablePageType.rootTab => state.arguments['index'],
      RestorablePageType.chat ||
      RestorablePageType.post ||
      RestorablePageType.notification =>
        state.arguments['underlyingRootTab'],
    };
    final index = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (index == null || index < 0 || index >= homeTabs) return 0;
    return index;
  }
}

/// 启动期一次解析出的导航计划：打底的 root tab 与可选的首屏深层页面。
///
/// `deepPage != null` 时视觉上直接进入该页面，返回后落到 [rootTabIndex]。
class StartupNavigationPlan {
  const StartupNavigationPlan({
    required this.rootTabIndex,
    this.deepPage,
  });

  final int rootTabIndex;
  final RestorablePageState? deepPage;
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _jpushSetup = false;
  bool _jpushSettingUp = false;
  bool _legalConsentDialogVisible = false;
  final HomeInitialTabResolver _homeInitialTabResolver =
      HomeInitialTabResolver();

  /// `lastPage` 模式下解析出的启动计划。账号变化或首帧前未解析时为 null。
  StartupNavigationPlan? _startupPlan;
  int? _planUserId;
  bool _startupPlanReady = false;
  int? _resolvingUserId;
  int _startupResolveGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final authProvider = context.read<AuthProvider>();
      if (authProvider.isLoggedIn &&
          (authProvider.user?.legalConsentsActive ?? false)) {
        _ensureJPush(authProvider);
      }
      _checkNativeNotificationOpen();
      _processPendingPrivateMessageOpen();
      _schedulePendingNotificationProcessing();
    }
  }

  Future<void> _ensureJPush(AuthProvider authProvider) async {
    if (_jpushSetup || _jpushSettingUp) return;

    if (!await PushSettingsService.isEnabled()) return;

    _jpushSettingUp = true;
    try {
      final result = await PushSettingsService.registerOnce(authProvider);
      _jpushSetup = result.registrationSucceeded;
      debugPrint(
        result.registrationSucceeded ? '✅ JPush 初始化成功' : result.message,
      );
    } catch (e, stack) {
      debugPrint('JPush 初始化失败，将在下次恢复时重试: $e');
      debugPrintStack(stackTrace: stack);
    } finally {
      _jpushSettingUp = false;
    }
  }

  void _presentRequiredLegalConsentDialog(AuthProvider authProvider) {
    if (_legalConsentDialogVisible) return;
    final user = authProvider.user;
    if (user == null ||
        user.legalConsentsActive ||
        !user.legalConsentsRequired) {
      return;
    }
    _legalConsentDialogVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final currentUser = authProvider.user;
      if (!authProvider.isLoggedIn ||
          currentUser == null ||
          currentUser.legalConsentsActive ||
          !currentUser.legalConsentsRequired) {
        _legalConsentDialogVisible = false;
        return;
      }
      await showRequiredLegalConsentDialog(
        context,
        requiresEduDataConsent: currentUser.eduAuthorized,
      );
      _legalConsentDialogVisible = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        if (!authProvider.isInitialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = authProvider.user;
        if (authProvider.isLoggedIn &&
            user != null &&
            !user.legalConsentsActive &&
            user.legalConsentsRequired) {
          _presentRequiredLegalConsentDialog(authProvider);
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (authProvider.isLoggedIn &&
            (authProvider.user?.legalConsentsActive ?? false)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (PlatformCapabilities.current.supportsJPush &&
                !_jpushSetup &&
                !_jpushSettingUp) {
              _ensureJPush(authProvider);
            }
            _processPendingPrivateMessageOpen();
            _schedulePendingNotificationProcessing();
            if (PlatformCapabilities.current.supportsJPush) {
              _checkNativeNotificationOpen();
            }
          });
        } else if (!authProvider.isLoggedIn) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _processPendingPrivateMessageOpen();
            _schedulePendingNotificationProcessing();
            if (PlatformCapabilities.current.supportsJPush) {
              _checkNativeNotificationOpen();
            }
          });
        }

        final tp = context.watch<ThemeProvider>();
        if (!tp.isLoaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (authProvider.isLoggedIn &&
            !(authProvider.user?.legalConsentsActive ?? true)) {
          return const PrivacyCenterScreen(restricted: true);
        }

        final userId = authProvider.user?.id;
        if (_startupPlanReady && _planUserId != userId) {
          // 账号变化才允许重新计算启动计划；同一账号修改“启动页面”只
          // 影响下一次启动，不能重建当前会话已经展示的根页面。
          _startupPlanReady = false;
          _startupPlan = null;
          _planUserId = null;
          _startupResolveGeneration++;
          _homeInitialTabResolver.reset();
        }

        // 启动计划只在当前 AuthWrapper 会话解析一次。尤其是 lastPage 的
        // 异步读取完成后，ThemeProvider 再次通知也不能触发当前页面跳转。
        if (!_startupPlanReady &&
            tp.startupDestination == StartupDestinationMode.lastPage &&
            userId != null &&
            userId > 0) {
          if (_startupPlan == null || _planUserId != userId) {
            _resolveStartupPlan(userId);
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
        }

        if (!_startupPlanReady) {
          // home / timetable（或 lastPage 但无有效用户）同步可解，不设门禁。
          _startupPlan = StartupNavigationPlan(
            rootTabIndex: _homeInitialTabResolver.resolve(tp, userId: userId),
          );
          _planUserId = userId;
          _startupPlanReady = true;
        }

        return HomeScreen(
          initialTab: _startupPlan!.rootTabIndex,
          initialDeepPage: _startupPlan!.deepPage,
        );
      },
    );
  }

  /// 异步解析 `lastPage` 启动计划：读取上次页面，计算打底 root tab 与
  /// 可选的首屏深层页面。外部导航目标（通知/私信/小组件）优先，抑制深层页。
  Future<void> _resolveStartupPlan(int userId) async {
    if (_resolvingUserId == userId) return;
    _resolvingUserId = userId;
    final currentGen = ++_startupResolveGeneration;

    try {
      final tp = context.read<ThemeProvider>();
      if (tp.startupDestination != StartupDestinationMode.lastPage) return;
      if (context.read<AuthProvider>().user?.id != userId) return;

      final externalTargetPending = _pendingPrivateMessageOpen.target != null ||
          _pendingNotificationOpen.target != null ||
          widgetTabSwitch.value > 0;

      RestorablePageState? state;
      if (!externalTargetPending) {
        try {
          state = await RootPageStateStore.instance.readLastPage(
            accountId: userId,
          );
        } catch (error) {
          DiagnosticLogService.instance.record(
            level: 'warning',
            source: '存储',
            type: '上次页面恢复失败',
            summary: '无法恢复上次退出时的页面',
            detail: error.toString(),
            eventCode: 'navigation_last_page_restore_failed',
            category: 'navigation',
            operation: 'restore',
            result: 'failure',
          );
        }
      }

      if (!mounted) return;
      if (currentGen != _startupResolveGeneration) return;
      if (context.read<AuthProvider>().user?.id != userId) return;

      setState(() {
        _planUserId = userId;
        _startupPlan = StartupNavigationPlan(
          rootTabIndex: _homeInitialTabResolver.resolve(
            tp,
            userId: userId,
            lastPage: state,
          ),
          deepPage: state == null || state.type == RestorablePageType.rootTab
              ? null
              : state,
        );
        _startupPlanReady = true;
      });
    } finally {
      if (_resolvingUserId == userId) {
        _resolvingUserId = null;
      }
    }
  }
}
