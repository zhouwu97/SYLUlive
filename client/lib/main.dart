import 'dart:async';
import 'dart:ui';
import 'dart:io' show File;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/post_provider.dart';
import 'providers/message_provider.dart';
import 'providers/edu_provider.dart';
import 'providers/course_schedule_provider.dart';
import 'providers/major_provider.dart';
import 'providers/teacher_provider.dart';
import 'providers/canteen_provider.dart';

import 'providers/social_provider.dart';
import 'models/user.dart';
import 'screens/chat_detail_screen.dart';
import 'screens/post_detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/course_schedule_screen.dart';
import 'screens/exam_schedule_screen.dart';
import 'screens/notifications_screen.dart';
import 'services/course_reminder_service.dart';
import 'theme/AppTheme.dart';
import 'config/api_constants.dart';
import 'utils/app_navigator.dart';
import 'utils/private_message_notification.dart';
import 'utils/notification_open_target.dart';
import 'services/diagnostic_log_service.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

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

final Map<String, int> _dedupTimes = {};

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

  if (level == 'warning') {
    DiagnosticLogService.instance.record(
      level: 'warning',
      source: source,
      type: type,
      summary: summary,
      detail: detail,
    );
  } else {
    DiagnosticLogService.instance.recordError(
      source: source,
      type: type,
      summary: summary,
      detail: detail,
    );
  }
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

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

        final fullString = details.toString();
        _safeRecord(
          level: 'error',
          source: 'Flutter',
          type: details.exception.runtimeType.toString(),
          summary: exceptionText,
          detail: fullString,
          dedupKey: _hashError(
            'error',
            'Flutter',
            details.exception.runtimeType.toString(),
            exceptionText,
            fullString,
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

      // 强制沉浸式（Edge-to-Edge），解决悬浮底栏下方的系统黑条空挡问题
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          statusBarColor: Colors.transparent,
        ),
      );

      await Hive.initFlutter();
      runApp(const MyApp());

      WidgetsBinding.instance.addPostFrameCallback((_) {
        CourseReminderService.instance.initialize();
        _initializePrivateMessageNotifications();
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
var jpush = JPush.newJPush();
final FlutterLocalNotificationsPlugin _privateMessageNotifications =
    FlutterLocalNotificationsPlugin();
bool _privateMessageNotificationsReady = false;
const MethodChannel _privateMessageNotificationChannel = MethodChannel(
  'shenliyuan/private_message_notifications',
);

// ── Alias 绑定状态追踪 ──
String? _lastBoundUserId;
String? _lastBoundRegistrationId;
int _aliasRetryCount = 0;
const int _maxAliasRetries = 3;
const List<int> _aliasRetryDelays = [0, 2, 5]; // 秒，指数退避

/// 冷启动时通知数据临时存放（navigator 未就绪前）
final PendingPrivateMessageOpen _pendingPrivateMessageOpen =
    PendingPrivateMessageOpen();

/// 冷启动时普通通知数据临时存放
final PendingNotificationOpen _pendingNotificationOpen =
    PendingNotificationOpen();

bool _jpushHandlersRegistered = false;
bool _pendingNotificationProcessScheduled = false;

void _ensureJPushHandlersRegistered() {
  if (_jpushHandlersRegistered) return;
  _jpushHandlersRegistered = true;

  jpush.addEventHandler(
    onReceiveNotification: (Map<String, dynamic> message) async {
      // 极光 SDK 已展示通知，不弹本地兜底，避免双通知
      await _handlePrivateMessageNotification(
        message,
        opened: false,
        showLocalFallback: false,
      );
    },
    onNotifyMessageUnShow: (Map<String, dynamic> message) async {
      // 极光 SDK 未展示通知，需要 Flutter 本地兜底
      await _handlePrivateMessageNotification(
        message,
        opened: false,
        showLocalFallback: true,
      );
    },
    onOpenNotification: (Map<String, dynamic> message) async {
      debugPrint('点击通知原始数据: $message');

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
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    _pendingNotificationOpen.store(target);
    _schedulePendingNotificationProcessing();
    return;
  }

  final now = DateTime.now();
  if (_isDuplicateNotificationOpen(target, now)) {
    debugPrint('忽略重复的通知跳转: ${target.type}');
    return;
  }

  _lastOpenedNotificationTarget = target;
  _lastOpenedNotificationAt = now;

  // 尝试拉起 App
  const channel = MethodChannel('shenliyuan/foreground');
  channel.invokeMethod('bringToForeground').catchError((e) {});

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
      return;

    case NotificationOpenType.marketPost:
      final postId = target.postId;
      if (postId == null) return;

      navigator.push(
        MaterialPageRoute(
          builder: (_) => PostDetailScreen(
            postId: postId,
            isMarket: true,
          ),
        ),
      );
      return;
  }
}

void _storeOrOpenNotificationTarget(NotificationOpenTarget target) {
  final navigator = appNavigatorKey.currentState;

  if (navigator != null) {
    _navigateToNotificationTarget(target);
    return;
  }

  _pendingNotificationOpen.store(target);
  _schedulePendingNotificationProcessing();
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

Future<void> setupJPush(AuthProvider authProvider) async {
  _ensureJPushHandlersRegistered();

  jpush.setup(
    appKey: ApiConstants.jpushAppKey,
    channel: 'developer-default',
    production: false,
    debug: true,
  );

  final rid = await jpush.getRegistrationID();

  if (rid.isNotEmpty) {
    await authProvider.updateDeviceToken(rid);
  }

  final userId = authProvider.user?.id;
  if (userId == null) return;

  final userIdStr = userId.toString();

  // 用户切换 → 重置旧 Alias 追踪状态
  if (_lastBoundUserId != null && _lastBoundUserId != userIdStr) {
    debugPrint('检测到用户切换: $_lastBoundUserId → $userIdStr，重置 Alias 状态');
    _lastBoundUserId = null;
    _lastBoundRegistrationId = null;
    _aliasRetryCount = 0;
  }

  // 三端校验后才跳过：内存状态 + 原生存储 + RegistrationID
  if (rid.isNotEmpty &&
      _lastBoundUserId == userIdStr &&
      _lastBoundRegistrationId == rid) {
    // 额外确认原生 SharedPreferences 中 Alias 未被清除（覆盖退出后同账号重登场景）
    String? storedAlias;
    try {
      final native = await _privateMessageNotificationChannel
          .invokeMapMethod<String, dynamic>('getPushDiagnostics');
      storedAlias = native?['storedAlias']?.toString();
    } catch (_) {
      // 原生查询失败 → 保守处理，不跳过
    }
    if (storedAlias == userIdStr) {
      debugPrint(
        'Alias 已绑定（三端一致），跳过: userId=$userIdStr '
        'rid=***${rid.substring(rid.length - 6)}',
      );
      return;
    }
    debugPrint('原生 Alias 缺失（stored=$storedAlias），重新绑定');
  }

  // RegistrationID 变化 → 需要重新绑定
  if (rid.isNotEmpty &&
      _lastBoundRegistrationId != null &&
      _lastBoundRegistrationId != rid) {
    debugPrint(
      'RegistrationID 已变化，重新绑定 Alias: '
      'old=***${_lastBoundRegistrationId!.substring(_lastBoundRegistrationId!.length - 6)} '
      'new=***${rid.substring(rid.length - 6)}',
    );
  }

  _aliasRetryCount = 0;
  await _tryBindAlias(userIdStr);
}

/// 带指数退避的 Alias 绑定（包含 RID 等待）
///
/// 首次尝试 + 最多 [_maxAliasRetries] 次重试（共 4 次调用机会），
/// 每次失败后按 [_aliasRetryDelays] 延迟后重试。
/// RID 为空和 setAlias 异常统一走重试逻辑。
/// 全部重试耗尽后抛出异常，使 setupJPush 感知失败，_jpushSetup 保持 false。
Future<void> _tryBindAlias(String userId) async {
  String? failureReason;
  bool isRidEmpty = false;

  try {
    final rid = await jpush.getRegistrationID();
    if (rid.isEmpty) {
      failureReason = 'RegistrationID 为空';
      isRidEmpty = true;
    } else {
      await jpush.setAlias(userId);

      // ── 成功 ──
      _lastBoundUserId = userId;
      _lastBoundRegistrationId = rid;
      _aliasRetryCount = 0;
      debugPrint(
        '✅ 成功设置 JPush Alias: $userId (rid=***${rid.substring(rid.length - 6)})',
      );
      DiagnosticLogService.instance.record(
        level: 'info',
        source: '推送',
        type: 'Alias 绑定成功',
        summary: 'Alias 绑定成功',
        detail: 'userId=$userId rid=***${rid.substring(rid.length - 6)}',
      );

      // 同步 alias 到原生层，供保活服务恢复时使用
      try {
        await _privateMessageNotificationChannel.invokeMethod(
          'syncAlias',
          {'userId': userId},
        );
      } catch (_) {}
      return;
    }
  } catch (e) {
    failureReason = e.toString();
    isRidEmpty = false;
  }

  // ── 失败：统一进入重试 ──
  _aliasRetryCount++;
  debugPrint('Alias 绑定失败 (第$_aliasRetryCount次): $failureReason');

  if (_aliasRetryCount <= _maxAliasRetries) {
    final delay = _aliasRetryDelays[_aliasRetryCount - 1];
    final source = isRidEmpty ? 'RegistrationID 等待' : 'Alias 重试';
    DiagnosticLogService.instance.record(
      level: 'warning',
      source: '推送',
      type: source,
      summary: failureReason,
      detail:
          'userId=$userId retry=$_aliasRetryCount/$_maxAliasRetries delay=${delay}s',
    );
    debugPrint('将在 ${delay}s 后重试');
    await Future.delayed(Duration(seconds: delay));
    await _tryBindAlias(userId);
    return;
  }

  // ── 重试耗尽：抛出异常，阻止 _jpushSetup = true ──
  final label = isRidEmpty ? 'RegistrationID' : 'Alias';
  final msg = '$label 重试 $_maxAliasRetries 次后仍失败: $failureReason';
  DiagnosticLogService.instance.record(
    level: 'error',
    source: '推送',
    type: 'Alias 绑定失败',
    summary: msg,
    detail: 'userId=$userId',
  );
  throw StateError(msg);
}

Future<void> _initializePrivateMessageNotifications() async {
  if (_privateMessageNotificationsReady) return;
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwin = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  const settings = InitializationSettings(android: android, iOS: darwin);
  await _privateMessageNotifications.initialize(
    settings,
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      try {
        final target = privateMessageTargetFromLocalPayload(payload);
        if (target != null) {
          _clearPrivateMessageNotifications(target.conversationId).ignore();
          _openPrivateMessage(target);
        }
      } catch (e) {
        debugPrint('解析私信本地通知 payload 失败: $e');
      }
    },
  );
  await _privateMessageNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          'developer-default',
          '系统通知',
          description: '评论、系统通知等',
          importance: Importance.low,
        ),
      );
  await _privateMessageNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          'private_messages',
          '私信通知',
          description: '收到新私信时悬浮提醒',
          importance: Importance.high,
        ),
      );
  // Android 13+ 运行时通知权限
  await _privateMessageNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  _privateMessageNotificationsReady = true;
}

/// 首帧后请求通知权限（需要 Activity 已创建）
Future<void> _requestNotificationPermissionIfNeeded() async {
  try {
    final plugin =
        _privateMessageNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (plugin == null) return;
    final granted = await plugin.requestNotificationsPermission();
    debugPrint('通知权限请求结果: $granted');
  } catch (e) {
    debugPrint('请求通知权限失败: $e');
  }
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
  final currentConversationId = provider?.currentConversationId;

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
    // 只有应用真正处于前台，并且用户正在看这个会话时才清理。
    await _clearPrivateMessageNotifications(target.conversationId);
    await provider?.refreshMessages();
    await provider?.markRead(target.conversationId);
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

  final payload = jsonEncode({
    'conversation_id': target.conversationId,
    'sender_id': target.senderId,
    'sender_name': target.displayName,
    'sender_avatar': target.senderAvatar,
    'message_id': target.messageId,
  });

  try {
    await _privateMessageNotifications.show(
      target.conversationId, // 同会话的通知会互相替换
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'private_messages',
          '私信通知',
          channelDescription: '收到新私信时悬浮提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: payload,
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
  // 尝试拉起 App
  const channel = MethodChannel('shenliyuan/foreground');
  channel.invokeMethod('bringToForeground').catchError((e) {});

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

void _navigateToPrivateMessage(PrivateMessageTarget target) {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    debugPrint('❌ navigate: navigator is null');
    return;
  }
  final resolvedTarget = _resolvePrivateMessageTarget(target);
  debugPrint(
    '🧭 navigate: popUntil+push conv=${resolvedTarget.conversationId} sender=${resolvedTarget.senderId}',
  );
  try {
    navigator.popUntil((route) => route.isFirst);
    navigator.push(
      MaterialPageRoute(
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
      ),
    );
    debugPrint('✅ navigate: push 成功');
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
    var launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
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
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ChangeNotifierProvider(create: (_) => PostProvider(dio)),
        ChangeNotifierProvider(create: (_) => MessageProvider(dio)),
        ChangeNotifierProvider(create: (_) => EduProvider(dio)),
        ChangeNotifierProvider(create: (_) => CourseScheduleProvider()),
        ChangeNotifierProvider(create: (_) => TeacherProvider(dio)),
        ChangeNotifierProvider(create: (_) => MajorProvider(dio)),
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider(create: (_) => SocialProvider(dio)),
      ],
      child: const _WidgetDeepLinkHandler(child: _AppContent()),
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
        if ((uri == 'widget_timetable' || uri == 'campus://timetable') &&
            mounted) {
          appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
          widgetTabSwitch.value++;
        } else if (uri != null && uri.startsWith('widget_exam') && mounted) {
          appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
          appNavigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => const ExamScheduleScreen()),
          );
        }
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
    if (state == AppLifecycleState.resumed) {
      _checkDeepLink();
    }
  }

  Future<void> _checkDeepLink() async {
    try {
      final uri = await _channel.invokeMethod<String>('getPendingDeepLink');
      if ((uri == 'widget_timetable' || uri == 'campus://timetable') &&
          mounted) {
        appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        // 切换到底部导航的课程表 tab，不 push 新页面
        widgetTabSwitch.value++;
      } else if (uri != null && uri.startsWith('widget_exam') && mounted) {
        appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        appNavigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const ExamScheduleScreen()),
        );
      }
    } catch (e) {
      debugPrint('深度链接检查失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
      scaffoldMessengerKey: scaffoldMessengerKey,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/timetable': (context) => const PredictiveBackGate(
              child: GlobalBackgroundWrapper(child: CourseScheduleScreen()),
            ),
      },
      home: const PredictiveBackGate(
        child: GlobalBackgroundWrapper(child: AuthWrapper()),
      ),
    );
  }
}

final GlobalKey<BackgroundWrapperState> backgroundWrapperKey =
    GlobalKey<BackgroundWrapperState>();

class GlobalBackgroundWrapper extends StatefulWidget {
  final Widget child;

  const GlobalBackgroundWrapper({super.key, required this.child});

  @override
  State<GlobalBackgroundWrapper> createState() => BackgroundWrapperState();
}

class BackgroundWrapperState extends State<GlobalBackgroundWrapper> {
  String _currentScreen = 'shuitie';

  void updateScreen(String screen) {
    if (_currentScreen != screen) {
      if (mounted) {
        setState(() {
          _currentScreen = screen;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Always render background in consistent structure
        _buildBackgroundLayer(themeProvider, isDark),
        // Child content
        widget.child,
      ],
    );
  }

  Widget _buildBackgroundLayer(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.shouldShowCustomBackground) {
      return _buildBackgroundImageLayer(themeProvider, isDark);
    }
    return _buildCleanBackground(isDark);
  }

  Widget _buildBackgroundImageLayer(ThemeProvider themeProvider, bool isDark) {
    String? bgPath = themeProvider.getCustomBackgroundImageFor(context);
    if (bgPath == null || bgPath.isEmpty) return _buildCleanBackground(isDark);
    final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
    final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
    final resolvedPath =
        isAsset ? ThemeProvider.resolveBundledAssetPath(bgPath) : bgPath;

    const alignment = Alignment.center;
    final fillScreen =
        themeProvider.getCustomBackgroundFillScreenFor(context) ||
            _isUsingFallbackDirection(themeProvider);

    final imageProvider = isAsset
        ? AssetImage(resolvedPath) as ImageProvider
        : isLocalFile
            ? FileImage(File(bgPath)) as ImageProvider
            : NetworkImage(bgPath) as ImageProvider;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundImage(
          imageProvider: imageProvider,
          alignment: alignment,
          isDark: isDark,
          fillScreen: fillScreen,
          blur: themeProvider.backgroundBlur,
        ),
        // Color overlay (fixed — componentOpacity controls GlassContainer, not background)
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  bool _isUsingFallbackDirection(ThemeProvider themeProvider) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return (isWide && !themeProvider.hasLandscapeBackground) ||
        (!isWide && !themeProvider.hasBackground);
  }

  Widget _buildBackgroundImage({
    required ImageProvider imageProvider,
    required Alignment alignment,
    required bool isDark,
    required bool fillScreen,
    required double blur,
  }) {
    if (fillScreen) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: alignment,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: 1.06,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              alignment: alignment,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(
                color:
                    isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
              ),
            ),
          ),
        ),
        Image(
          image: imageProvider,
          fit: BoxFit.contain,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildCleanBackground(bool isDark) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF101219) : const Color(0xFFF8FAFC),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _jpushSetup = false;
  bool _jpushSettingUp = false;

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
      if (authProvider.isLoggedIn) {
        _ensureJPush(authProvider);
        _checkNativePrivateMessage();
      }
      _processPendingPrivateMessageOpen();
      _schedulePendingNotificationProcessing();
    }
  }

  bool _checkingNativePrivateMessage = false;

  Future<void> _checkNativePrivateMessage() async {
    if (_checkingNativePrivateMessage) return;
    _checkingNativePrivateMessage = true;

    try {
      final payload = await _privateMessageNotificationChannel
          .invokeMethod<String>('getPendingPrivateMessage');

      if (payload == null || payload.isEmpty) return;

      final target = privateMessageTargetFromLocalPayload(payload);
      if (target == null) {
        debugPrint('原生私信通知参数解析失败: $payload');
        return;
      }

      await _clearPrivateMessageNotifications(target.conversationId);
      _openPrivateMessage(target);
    } catch (e) {
      debugPrint('读取原生待处理私信失败: $e');
    } finally {
      _checkingNativePrivateMessage = false;
    }
  }

  Future<void> _ensureJPush(AuthProvider authProvider) async {
    if (_jpushSetup || _jpushSettingUp) return;

    _jpushSettingUp = true;
    try {
      await setupJPush(authProvider);
      _jpushSetup = true;
      debugPrint('✅ JPush 初始化成功');
    } catch (e, stack) {
      debugPrint('JPush 初始化失败，将在下次恢复时重试: $e');
      debugPrintStack(stackTrace: stack);
    } finally {
      _jpushSettingUp = false;
    }
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

        if (authProvider.isLoggedIn) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_jpushSetup && !_jpushSettingUp) {
              _ensureJPush(authProvider);
              _requestNotificationPermissionIfNeeded();
            }
            _processPendingPrivateMessageOpen();
            _schedulePendingNotificationProcessing();
            _checkNativePrivateMessage();
          });
        }

        final tp = context.watch<ThemeProvider>();
        return HomeScreen(initialTab: tp.startOnTimetable ? 2 : 0);
      },
    );
  }
}

/// 预测性返回手势开关门控
/// 通过 ThemeProvider.predictiveBack 控制，默认开启
class PredictiveBackGate extends StatelessWidget {
  final Widget child;
  const PredictiveBackGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // 这里不再由全局接管拦截逻辑，而是由子页面按需拦截
    return child;
  }
}
