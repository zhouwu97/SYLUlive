import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import 'reply_notification_state.dart';

/// 统一处理应用从后台恢复后的轻量同步。
///
/// 页面自身仍然负责首次加载和可见页面的局部刷新；这里只负责跨页面共享的
/// 会话、私信列表和回复未读状态，避免每个页面各自监听生命周期而重复请求。
class AppResumeCoordinator {
  AppResumeCoordinator._();

  static final AppResumeCoordinator instance = AppResumeCoordinator._();

  static const _refreshAfter = Duration(seconds: 15);
  static const _deepRefreshAfter = Duration(minutes: 2);

  DateTime? _backgroundAt;
  Future<void>? _runningRefresh;
  final Set<Future<void> Function()> _visibleRefreshers =
      <Future<void> Function()>{};

  /// 注册当前可见根页面的轻量刷新，返回值用于页面销毁时取消注册。
  VoidCallback registerVisibleRefresh(Future<void> Function() refresher) {
    _visibleRefreshers.add(refresher);
    return () => _visibleRefreshers.remove(refresher);
  }

  void onLifecycleChanged(BuildContext context, AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;

    final backgroundAt = _backgroundAt;
    _backgroundAt = null;
    if (backgroundAt == null ||
        DateTime.now().difference(backgroundAt) < _refreshAfter ||
        _runningRefresh != null) {
      return;
    }

    final deepRefresh =
        DateTime.now().difference(backgroundAt) >= _deepRefreshAfter;
    final refresh = _runRefresh(context, deepRefresh: deepRefresh);
    _runningRefresh = refresh;
    unawaited(_observeRefresh(refresh));
  }

  Future<void> _observeRefresh(Future<void> refresh) async {
    try {
      await refresh;
    } catch (error, stackTrace) {
      debugPrint('前台恢复同步异常: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (identical(_runningRefresh, refresh)) {
        _runningRefresh = null;
      }
    }
  }

  Future<void> _runRefresh(
    BuildContext context, {
    required bool deepRefresh,
  }) async {
    if (!context.mounted) return;
    final auth = context.read<AuthProvider>();
    final accountId = auth.user?.id;
    final sessionGeneration = auth.sessionGeneration;
    if (!auth.isLoggedIn || accountId == null || accountId <= 0) return;

    final messageProvider = context.read<MessageProvider>();
    await _safeRun(
      '私信列表同步',
      () => messageProvider.loadConversations(silent: true),
    );

    final visibleRefreshers = List<Future<void> Function()>.of(
      _visibleRefreshers,
    );
    await Future.wait(
      visibleRefreshers.map(
        (refresher) => _safeRun('当前页面同步', refresher),
      ),
    );

    if (deepRefresh) {
      await _safeRun('会话信息同步', auth.refreshUser);
    }

    if (!context.mounted || !_sameSession(auth, accountId, sessionGeneration)) {
      return;
    }
    ReplyNotificationState.instance.requestRefresh(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
    );
  }

  bool _sameSession(AuthProvider auth, int accountId, int generation) {
    return auth.isLoggedIn &&
        auth.user?.id == accountId &&
        auth.sessionGeneration == generation;
  }

  Future<void> _safeRun(String label, Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      debugPrint('恢复同步失败（$label）: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}
