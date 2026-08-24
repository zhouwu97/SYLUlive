import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import 'reply_notification_state.dart';

class _VisibleRefreshEntry {
  const _VisibleRefreshEntry(this.refresher, this.isVisible);

  final Future<void> Function() refresher;
  final bool Function()? isVisible;
}

/// 统一处理应用从后台恢复后的轻量同步。
///
/// 页面自身仍然负责首次加载和可见页面的局部刷新；这里只负责跨页面共享的
/// 会话、私信列表和回复未读状态，避免每个页面各自监听生命周期而重复请求。
class AppResumeCoordinator {
  AppResumeCoordinator._()
      : _now = DateTime.now,
        _refreshAfter = const Duration(seconds: 15),
        _deepRefreshAfter = const Duration(minutes: 2);

  @visibleForTesting
  AppResumeCoordinator.test({
    required DateTime Function() now,
    Duration refreshAfter = Duration.zero,
    Duration deepRefreshAfter = const Duration(minutes: 2),
  })  : _now = now,
        _refreshAfter = refreshAfter,
        _deepRefreshAfter = deepRefreshAfter;

  static final AppResumeCoordinator instance = AppResumeCoordinator._();

  final DateTime Function() _now;
  final Duration _refreshAfter;
  final Duration _deepRefreshAfter;

  DateTime? _backgroundAt;
  Future<void>? _runningRefresh;
  final Set<_VisibleRefreshEntry> _visibleRefreshers = <_VisibleRefreshEntry>{};

  @visibleForTesting
  Future<void>? get debugRunningRefresh => _runningRefresh;

  /// 注册当前可见根页面的轻量刷新，返回值用于页面销毁时取消注册。
  /// [isVisible] 用于 KeepAlive 根页面，避免后台恢复时刷新不可见页面。
  VoidCallback registerVisibleRefresh(
    Future<void> Function() refresher, {
    bool Function()? isVisible,
  }) {
    final entry = _VisibleRefreshEntry(refresher, isVisible);
    _visibleRefreshers.add(entry);
    return () => _visibleRefreshers.remove(entry);
  }

  void onLifecycleChanged(BuildContext context, AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundAt ??= _now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;

    final backgroundAt = _backgroundAt;
    _backgroundAt = null;
    final now = _now();
    if (backgroundAt == null ||
        now.difference(backgroundAt) < _refreshAfter ||
        _runningRefresh != null) {
      return;
    }

    final deepRefresh = now.difference(backgroundAt) >= _deepRefreshAfter;
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
    final accountSessionEpoch = auth.accountSessionEpoch;
    if (!auth.isLoggedIn || accountId == null || accountId <= 0) return;

    final messageProvider = context.read<MessageProvider>();
    await _safeRun(
      '私信列表同步',
      () => messageProvider.loadConversations(silent: true),
    );
    if (!context.mounted ||
        !_sameSession(
          auth,
          accountId,
          sessionGeneration,
          accountSessionEpoch,
        )) {
      return;
    }

    final visibleRefreshers = _visibleRefreshers
        .where((entry) {
          try {
            return entry.isVisible?.call() ?? true;
          } catch (error, stackTrace) {
            debugPrint('恢复同步可见性判断失败: $error');
            debugPrintStack(stackTrace: stackTrace);
            return false;
          }
        })
        .map((entry) => entry.refresher)
        .toList(growable: false);
    await Future.wait(
      visibleRefreshers.map(
        (refresher) => _safeRun('当前页面同步', refresher),
      ),
    );
    if (!context.mounted ||
        !_sameSession(
          auth,
          accountId,
          sessionGeneration,
          accountSessionEpoch,
        )) {
      return;
    }

    if (deepRefresh) {
      await _safeRun('会话信息同步', auth.refreshUser);
    }

    if (!context.mounted ||
        !_sameSession(
          auth,
          accountId,
          sessionGeneration,
          accountSessionEpoch,
        )) {
      return;
    }
    ReplyNotificationState.instance.requestRefresh(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
    );
  }

  bool _sameSession(
    AuthProvider auth,
    int accountId,
    int generation,
    int accountSessionEpoch,
  ) {
    return auth.isLoggedIn &&
        auth.user?.id == accountId &&
        auth.sessionGeneration == generation &&
        auth.accountSessionEpoch == accountSessionEpoch;
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
