import 'package:flutter/foundation.dart';

enum ReplyNotificationStateChangeType {
  read,
  allRead,
  refreshRequested,
}

class ReplyNotificationStateChange {
  final ReplyNotificationStateChangeType type;
  final int? notificationId;

  const ReplyNotificationStateChange._({
    required this.type,
    this.notificationId,
  });

  const ReplyNotificationStateChange.read(int notificationId)
      : this._(
          type: ReplyNotificationStateChangeType.read,
          notificationId: notificationId,
        );

  const ReplyNotificationStateChange.allRead()
      : this._(type: ReplyNotificationStateChangeType.allRead);

  const ReplyNotificationStateChange.refreshRequested()
      : this._(type: ReplyNotificationStateChangeType.refreshRequested);
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

  void markRead(int notificationId) {
    if (notificationId <= 0) return;
    _emit(ReplyNotificationStateChange.read(notificationId));
  }

  void notifyAllRead() {
    _emit(const ReplyNotificationStateChange.allRead());
  }

  void requestRefresh() {
    _emit(const ReplyNotificationStateChange.refreshRequested());
  }

  void _emit(ReplyNotificationStateChange change) {
    _lastChange = change;
    _version++;
    notifyListeners();
  }
}
