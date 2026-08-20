import 'package:flutter/foundation.dart';

enum ReplyNotificationStateChangeType {
  read,
  allRead,
  refreshRequested,
}

class ReplyNotificationStateChange {
  final int accountId;
  final int sessionGeneration;
  final ReplyNotificationStateChangeType type;
  final int? notificationId;

  const ReplyNotificationStateChange._({
    required this.accountId,
    required this.sessionGeneration,
    required this.type,
    this.notificationId,
  });

  const ReplyNotificationStateChange.read({
    required int accountId,
    required int sessionGeneration,
    required int notificationId,
  }) : this._(
          accountId: accountId,
          sessionGeneration: sessionGeneration,
          type: ReplyNotificationStateChangeType.read,
          notificationId: notificationId,
        );

  const ReplyNotificationStateChange.allRead({
    required int accountId,
    required int sessionGeneration,
  }) : this._(
          accountId: accountId,
          sessionGeneration: sessionGeneration,
          type: ReplyNotificationStateChangeType.allRead,
        );

  const ReplyNotificationStateChange.refreshRequested({
    required int accountId,
    required int sessionGeneration,
  }) : this._(
          accountId: accountId,
          sessionGeneration: sessionGeneration,
          type: ReplyNotificationStateChangeType.refreshRequested,
        );
}

/// 回复未读提醒的跨页面同步通道。
///
/// 这是一个事件源，不缓存服务端数据：单条/全部已读用于即时更新，
/// [requestRefresh] 用于让当前首页重新向服务端校准最终状态。
class ReplyNotificationState extends ChangeNotifier {
  ReplyNotificationState._();

  static final ReplyNotificationState instance = ReplyNotificationState._();

  ReplyNotificationStateChange? _lastChange;
  int _version = 0;

  ReplyNotificationStateChange? get lastChange => _lastChange;
  int get version => _version;

  void markRead({
    required int accountId,
    required int sessionGeneration,
    required int notificationId,
  }) {
    if (accountId <= 0 || notificationId <= 0) return;
    _emit(ReplyNotificationStateChange.read(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
      notificationId: notificationId,
    ));
  }

  void notifyAllRead({
    required int accountId,
    required int sessionGeneration,
  }) {
    if (accountId <= 0) return;
    _emit(ReplyNotificationStateChange.allRead(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
    ));
  }

  void requestRefresh({
    required int accountId,
    required int sessionGeneration,
  }) {
    if (accountId <= 0) return;
    _emit(ReplyNotificationStateChange.refreshRequested(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
    ));
  }

  void _emit(ReplyNotificationStateChange change) {
    _lastChange = change;
    _version++;
    notifyListeners();
  }
}
