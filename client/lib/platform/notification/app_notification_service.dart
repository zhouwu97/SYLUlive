import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sylulive_push_bridge/sylulive_push_bridge.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/diagnostic_log_service.dart';
import '../../utils/notification_open_target.dart';
import '../../utils/private_message_notification.dart';
import '../app_platform.dart';
import 'notification_service.dart';

/// 标准平台的应用通知协调器。
///
/// 应用层只处理用户、路由和消息语义；供应商 SDK、原生通道以及平台通知类型
/// 全部封装在 `sylulive_push_bridge` 中。OHOS 构建通过依赖覆盖解析同名空实现。
///
/// 依赖导航的打开动作由 [configureHandlers] 注入，避免协调器反向持有 Widget 树。
class AppNotificationService implements NotificationService {
  AppNotificationService._();

  static final AppNotificationService instance = AppNotificationService._();

  // ── 由 main.dart 注入的依赖 ────────────────────────────────
  /// 处理私信通知（保留成功 / 失败语义：true 表示本条已被消费）。
  /// main.dart 注入实现，因依赖 navigator / MessageProvider，无法迁出。
  PrivateMessageNotificationHandler? _onPrivateMessageNotification;

  /// 通用通知点击后的“拉起 App + 路由跳转”分发。
  NotificationOpenHandler? _onNotificationOpenTarget;

  PrivateMessageOpenHandler? _onOpenPrivateMessage;

  /// 由 main.dart 在 app 启动阶段注入。
  @override
  void configureHandlers({
    required PrivateMessageNotificationHandler onPrivateMessageNotification,
    required NotificationOpenHandler onNotificationOpenTarget,
    required PrivateMessageOpenHandler onOpenPrivateMessage,
  }) {
    _onPrivateMessageNotification = onPrivateMessageNotification;
    _onNotificationOpenTarget = onNotificationOpenTarget;
    _onOpenPrivateMessage = onOpenPrivateMessage;
  }

  final SylulivePushBridge _bridge = SylulivePushBridge.create();
  bool _pushHandlersRegistered = false;

  final Set<String> _shownLocalMessageIds = {};

  /// 供 main.dart 的 `_handlePrivateMessageNotification` 检查是否已初始化。
  @override
  bool get isReadyForPrivateMessages => _bridge.localNotificationsReady;

  // ── NotificationService 接口实现 ────────────────────────
  @override
  AppPlatform get platform => AppPlatform.android;

  @override
  bool get isSupported => true;

  @override
  Future<void> init() => initializePrivateMessageNotifications();

  @override
  Future<bool> requestPermissions() async {
    try {
      final granted = await _bridge.requestNotificationsPermission();
      debugPrint('通知权限请求结果: $granted');
      return granted;
    } catch (e) {
      debugPrint('请求通知权限失败: $e');
      return false;
    }
  }

  @override
  Future<void> showLocal({
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      await _bridge.showLocalNotification(
        id: 0,
        title: title,
        body: body,
        channelId: 'developer-default',
        channelName: '系统通知',
        channelDescription: '评论、系统通知等',
        highPriority: false,
        payload: payload,
      );
    } catch (e) {
      debugPrint('本地通知弹出失败: $e');
    }
  }

  @override
  Future<void> clearAll() async {
    try {
      await _bridge.cancelAllLocalNotifications();
    } catch (e) {
      debugPrint('清空本地通知失败: $e');
    }
  }

  @override
  Future<void> dispose() async {
    // 当前桥接层不暴露显式释放接口；留空保持契约，便于后续扩展。
  }

  /// 标准平台推送初始化（包含设备标识上报和 Alias 同步）。
  @override
  Future<void> setupPush(AuthProvider authProvider) async {
    if (ApiConstants.jpushAppKey.isEmpty) {
      DiagnosticLogService.instance.record(
        level: 'error',
        source: '推送',
        type: 'JPush 配置缺失',
        summary: 'JPUSH_APP_KEY 为空，已跳过初始化',
        detail: '请通过 --dart-define=JPUSH_APP_KEY 注入或设置默认值',
      );
      return;
    }

    _ensurePushHandlersRegistered();

    _bridge.setup(
      appKey: ApiConstants.jpushAppKey,
      channel: 'developer-default',
      production: false,
      debug: true,
    );

    final rid = await _bridge.getRegistrationID();

    if (rid.isNotEmpty) {
      await authProvider.updateDeviceToken(rid);
    }

    final userId = authProvider.user?.id;
    if (userId == null) return;

    final userIdStr = userId.toString();

    // 将 userId 同步给原生层，后续的 Alias 绑定与退避重试完全由原生层
    // KeepAliveForegroundService 的 reconcileAliasState 机制接管
    try {
      await _bridge.syncAlias(userIdStr);
    } catch (e) {
      debugPrint('同步 Alias 到原生层失败: $e');
    }
  }

  /// 对应原 `main.dart::_initializePrivateMessageNotifications()`。
  Future<void> initializePrivateMessageNotifications() async {
    await _bridge.initializeLocalNotifications(
      onTap: (payload) {
        try {
          final target = privateMessageTargetFromLocalPayload(payload);
          if (target != null) {
            clearConversationNotifications(target.conversationId).ignore();
            _onPrivateMessageTargetFromLocalPayload(target);
          }
        } catch (e) {
          debugPrint('解析私信本地通知 payload 失败: $e');
        }
      },
    );
  }

  /// 调用 main.dart 注入的 `_openPrivateMessage` 回调。
  /// 由于本服务仅是被 `initializePrivateMessageNotifications` 的 onDidReceiveNotificationResponse
  /// 触发，而真的“拉起 App + 路由跳转”逻辑在 main.dart 中，
  /// 用上一次注入的私信回调（opened=true）复用 main.dart 的 `_handlePrivateMessageNotification`
  /// 不太合适——这里直接用注入的 `onNotificationOpenTarget` 不匹配目标类型。
  ///
  void _onPrivateMessageTargetFromLocalPayload(PrivateMessageTarget target) {
    final cb = _onOpenPrivateMessage;
    if (cb != null) {
      cb(target);
    } else {
      debugPrint('未注入打开私信回调，无法处理 ${target.conversationId}');
    }
  }

  @override
  Future<String?> getPendingPrivateMessage() async {
    try {
      return await _bridge.getPendingPrivateMessage();
    } catch (e) {
      debugPrint('读取原生待处理私信失败: $e');
      return null;
    }
  }

  /// 对应原 `main.dart::_clearPrivateMessageNotifications(int)`。
  @override
  Future<void> clearConversationNotifications(int conversationId) async {
    try {
      await _bridge.clearConversationNotifications(conversationId);
    } catch (e) {
      debugPrint('清理私信通知失败: $e');
    }
  }

  /// 对应原 `main.dart::_showPrivateMessageLocalNotification(target, message)`。
  /// 极光未展示通知时由 main.dart 的 `_handlePrivateMessageNotification` 调用兜底弹窗。
  @override
  Future<void> showLocalPrivateMessage(
    PrivateMessageTarget target,
    Map<String, dynamic> message,
  ) async {
    if (!isReadyForPrivateMessages) return;

    final msgId = extractPushExtras(message)['msg_id']?.toString() ?? '';
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
      await _bridge.showLocalNotification(
        id: target.conversationId, // 同会话的通知会互相替换
        title: title,
        body: body,
        channelId: 'private_messages',
        channelName: '私信通知',
        channelDescription: '收到新私信时悬浮提醒',
        highPriority: true,
        payload: payload,
      );
      debugPrint('✅ 本地私信通知已弹出: ${target.displayName}');
    } catch (e) {
      debugPrint('本地私信通知弹出失败: $e');
    }
  }

  /// 对应原 `main.dart::_handleUpdateNotification(message)`。
  /// 极光推送“应用更新”通知触发后唤醒外部浏览器打开下载链接。
  Future<bool> handleUpdateNotification(Map<String, dynamic> message) async {
    final extras = extractPushExtras(message);
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

  // ── 推送事件分发（注册内部回调，依赖 main.dart 注入处理器） ──
  void _ensurePushHandlersRegistered() {
    if (_pushHandlersRegistered) return;
    _pushHandlersRegistered = true;

    final onPrivateMessage = _onPrivateMessageNotification;
    final onOpenTarget = _onNotificationOpenTarget;

    _bridge.addEventHandler(
      onReceiveNotification: (Map<String, dynamic> message) async {
        if (onPrivateMessage == null) return;
        // 极光 SDK 已展示通知，不弹本地兜底，避免双通知
        await onPrivateMessage(
          message,
          opened: false,
          showLocalFallback: false,
        );
      },
      onNotifyMessageUnShow: (Map<String, dynamic> message) async {
        if (onPrivateMessage == null) return;
        // 极光 SDK 未展示通知，需要 Flutter 本地兜底
        await onPrivateMessage(
          message,
          opened: false,
          showLocalFallback: true,
        );
      },
      onOpenNotification: (Map<String, dynamic> message) async {
        debugPrint('点击通知原始数据: $message');

        if (await handleUpdateNotification(message)) return;
        if (onPrivateMessage != null) {
          final handled = await onPrivateMessage(message, opened: true);
          if (handled) {
            return;
          }
        }

        final target = NotificationOpenTarget.parse(message);

        if (target == null) {
          final extras = extractPushExtras(message);
          debugPrint('忽略未知或无效通知: type=${extras['type']}');
          return;
        }

        onOpenTarget?.call(target);
      },
    );
  }
}
