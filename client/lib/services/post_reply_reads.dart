import 'dart:async';

import 'package:flutter/foundation.dart';

import '../providers/auth_provider.dart';
import 'publish_session_scope.dart';
import 'reply_notification_service.dart';
import 'reply_notification_session.dart';
import 'reply_notification_state.dart';

/// 详情页与楼中楼共用同一份当前账号、本帖的未读映射。
class PostReplyReads extends ChangeNotifier {
  PostReplyReads(this.auth, this.postId, {int? targetReplyId})
      : _target = targetReplyId,
        session = ReplyNotificationSession.capture(auth);

  final AuthProvider auth;
  final int postId;
  final ReplyNotificationSession session;
  late final _service = ReplyNotificationService(auth.dio,
      recipientUserId: session.accountId,
      isCurrentSession: () => session.isCurrent(auth));
  late final _scope = PublishSessionScope(
      accountId: session.accountId!, accountSessionEpoch: session.accountEpoch);
  int? _target;
  Map<int, List<int>> _unread = {};
  final _confirmed = <int>{};
  final _ready = <int>{};
  bool _writing = false;
  bool _closed = false;
  int _request = 0;
  int _revision = 0;
  Timer? _batch;

  int? watchRevision(int replyId) =>
      _revision > 0 && (_unread.containsKey(replyId) || replyId == _target)
          ? _revision
          : null;

  Future<void> refresh() async {
    if (_closed || !session.isCurrent(auth)) return;
    final request = ++_request;
    try {
      final unread = await _service.fetchPostUnread(postId);
      if (_closed || request != _request || !session.isCurrent(auth)) return;
      for (final ids in unread.values) {
        ids.removeWhere(_confirmed.contains);
      }
      _unread = unread..removeWhere((_, ids) => ids.isEmpty);
    } catch (_) {
      // 旧服务仍可按跳转目标精确消费；普通浏览等待下次刷新恢复未读映射。
      if (_closed || request != _request || !session.isCurrent(auth)) return;
    }
    _revision++;
    notifyListeners();
  }

  void seen(int replyId) {
    if (_closed || !session.isCurrent(auth) || watchRevision(replyId) == null) {
      return;
    }
    _ready.add(replyId);
    _batch ??= Timer(const Duration(milliseconds: 50), _flush);
  }

  Future<void> _flush() async {
    _batch?.cancel();
    _batch = null;
    if (_writing) return;
    _writing = true;
    try {
      while (_ready.isNotEmpty && session.isCurrent(auth)) {
        final replies = Set<int>.of(_ready);
        _ready.clear();
        final byId = {
          for (final reply in replies)
            for (final id in _unread[reply] ?? const <int>[]) id: reply
        };
        final ids = byId.keys.toList();
        for (var offset = 0; offset < ids.length; offset += 100) {
          final chunk = ids.skip(offset).take(100).toList();
          final replyIds = chunk.map((id) => byId[id]!).toSet();
          await _service.markSelected(chunk,
              replyIds: replyIds.toList(), session: _scope);
          _confirmed.addAll(chunk);
          for (final reply in replyIds) {
            final remaining = _unread[reply];
            remaining?.removeWhere(_confirmed.contains);
            if (remaining == null || remaining.isEmpty) _unread.remove(reply);
            if (reply == _target) _target = null;
          }
          _refreshHome();
        }
        final target = _target;
        if (target != null && replies.contains(target)) {
          // 已读历史或旧版服务无法提供未读映射时，仍可同步目标自身的系统提醒。
          await _service.markReplyRead(
              postId: postId, replyId: target, session: _scope);
          _target = null;
          _refreshHome();
        }
      }
    } catch (_) {
      // 保留未读映射，下次重新看到或刷新后可再提交。
    } finally {
      _writing = false;
      if (!_closed) notifyListeners();
      if (_ready.isNotEmpty && session.isCurrent(auth)) unawaited(_flush());
    }
  }

  void _refreshHome() {
    if (session.isCurrent(auth)) {
      ReplyNotificationState.instance.requestRefresh(
          accountId: session.accountId!,
          sessionGeneration: auth.sessionGeneration);
    }
  }

  @override
  void dispose() {
    _closed = true;
    // 离开前只提交已经满足停留时长的回复。
    if (_batch != null) unawaited(_flush());
    super.dispose();
  }
}
