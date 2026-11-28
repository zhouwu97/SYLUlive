import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:jpush_flutter/harmony/jpush_harmony_sdk.dart';
import 'package:jpush_flutter/jpush_interface.dart';

import '../contracts/push_client.dart';
import '../contracts/system_notification_client.dart';
import '../../utils/private_message_notification.dart';

class OhosPushClient implements PushClient, SystemNotificationClient {
  final _sdk = JpushHarmonySdk();
  static const _native =
      MethodChannel('shenliyuan/private_message_notifications');
  bool _started = false;
  Future<void>? _initializing;
  void Function(Map<String, dynamic>)? _localTap;

  @override
  void setup(
      {required String appKey,
      required String channel,
      required bool production,
      required bool debug}) {
    if (_started) return;
    _sdk.setUserRequestNotificationPermission(enable: true);
    _sdk.setup(
        appKey: appKey, channel: channel, production: production, debug: false);
    _started = true;
    _initializing = _enableDelivery();
  }

  Future<void> _enableDelivery() async {
    await _sdk.resumePush();
    if (_started) await _native.invokeMethod<void>('consumePushWant');
  }

  @override
  Future<String?> getRegistrationId() async {
    if (!_started) return null;
    final initializing = _initializing;
    try {
      await initializing;
    } catch (_) {
      if (identical(initializing, _initializing)) _started = false;
      rethrow;
    }
    if (!_started) return null;
    final rid = await _sdk.getRegistrationID();
    return !_started || rid.isEmpty ? null : rid;
  }

  @override
  Future<bool> setPushOptIn(bool enabled) async {
    if (_started) {
      if (enabled) {
        await _sdk.resumePush();
      } else {
        _started = false;
        await _sdk.stopPush();
        await _sdk.clearLocalNotifications();
      }
    }
    return true;
  }

  @override
  Future<void> clearAlias() async {
    if (_started) await _sdk.deleteAlias();
  }

  @override
  Future<void> setTags(List<String> tags) async {
    if (_started) await _sdk.setTags(tags);
  }

  @override
  Future<bool> requestSystemNotificationPermission() async =>
      await _native.invokeMethod<bool>('requestPermission') ?? false;

  @override
  void setHandlers({
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onOpenNotification,
    Future<dynamic> Function(Map<String, dynamic>)? onReceiveMessage,
    Future<dynamic> Function(Map<String, dynamic>)? onNotifyMessageUnShow,
  }) {
    _sdk.setCallBackHarmony((name, raw) async {
      if (!_started || raw is! Map) return;
      final message = Map<String, dynamic>.from(raw);
      if (message['extras'] case final String extras) {
        try {
          message['extras'] = jsonDecode(extras);
        } on FormatException {
          return;
        }
      }
      if (message['notificationType'] == 1) {
        if (name == 'onClickMessage') {
          _localTap?.call(extractJPushExtras(message));
        }
        return;
      }
      final handler = switch (name) {
        'onClickMessage' => onOpenNotification,
        'onArrivedMessage' => onReceiveNotification,
        'onCustomMessage' => onReceiveMessage,
        'onUnShowMessage' => onNotifyMessageUnShow,
        _ => null,
      };
      await handler?.call(message);
    });
  }

  @override
  Future<void> initialize(
      {required void Function(Map<String, dynamic>) onNotificationTap}) async {
    _localTap = onNotificationTap;
  }

  @override
  Future<void> showNotification(
      {required int id,
      required String title,
      required String body,
      required Map<String, dynamic> payload}) async {
    if (!_started) return;
    final extra = {
      for (final entry in payload.entries)
        if (entry.value != null) entry.key: entry.value.toString()
    };
    await _sdk.sendLocalNotification(LocalNotification(
      id: id,
      title: title,
      content: body,
      extra: extra,
      fireTime: DateTime.now(),
    ));
  }

  @override
  Future<void> cancelAll() async {
    if (_started) await _sdk.clearLocalNotifications();
  }
}
