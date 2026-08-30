import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/services/app_resume_coordinator.dart';
import 'package:shenliyuan/services/reply_notification_state.dart';

class _FakeAuthProvider extends Fake
    with ChangeNotifier
    implements AuthProvider {
  int? userId = 1;
  int tokenGeneration = 1;
  int accountEpoch = 1;
  int refreshUserCalls = 0;

  @override
  bool get isLoggedIn => userId != null;

  @override
  User? get user => userId == null
      ? null
      : User(
          id: userId!,
          studentId: '20260001',
          nickname: '恢复测试用户',
          avatar: '',
          createdAt: DateTime(2026, 1, 1),
        );

  @override
  int get sessionGeneration => tokenGeneration;

  @override
  int get accountSessionEpoch => accountEpoch;

  @override
  Future<void> refreshUser() async {
    refreshUserCalls++;
  }

  void switchAccount(int? nextUserId) {
    userId = nextUserId;
    tokenGeneration++;
    accountEpoch++;
    notifyListeners();
  }
}

class _FakeMessageProvider extends Fake
    with ChangeNotifier
    implements MessageProvider {
  int loadCalls = 0;
  Completer<void>? gate;
  Completer<void> started = Completer<void>();

  @override
  Future<void> loadConversations({bool silent = false}) async {
    loadCalls++;
    if (!started.isCompleted) started.complete();
    await gate?.future;
  }
}

Future<BuildContext> _pumpContext(
  WidgetTester tester,
  _FakeAuthProvider auth,
  _FakeMessageProvider messages,
) async {
  late BuildContext result;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<MessageProvider>.value(value: messages),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            result = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('私信同步期间切换账号会阻止后续可见页与回复刷新', (tester) async {
    var now = DateTime(2026, 8, 24, 10);
    final coordinator = AppResumeCoordinator.test(now: () => now);
    final auth = _FakeAuthProvider();
    final messages = _FakeMessageProvider()..gate = Completer<void>();
    final context = await _pumpContext(tester, auth, messages);
    var visibleRefreshCalls = 0;
    coordinator.registerVisibleRefresh(() async => visibleRefreshCalls++);
    final replyVersion = ReplyNotificationState.instance.version;

    coordinator.onLifecycleChanged(context, AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 20));
    coordinator.onLifecycleChanged(context, AppLifecycleState.resumed);
    await messages.started.future;
    final refresh = coordinator.debugRunningRefresh!;

    auth.switchAccount(2);
    messages.gate!.complete();
    await refresh;

    expect(messages.loadCalls, 1);
    expect(visibleRefreshCalls, 0);
    expect(auth.refreshUserCalls, 0);
    expect(ReplyNotificationState.instance.version, replyVersion);
  });

  testWidgets('可见页同步期间切换账号会阻止深刷新和回复刷新', (tester) async {
    var now = DateTime(2026, 8, 24, 10);
    final coordinator = AppResumeCoordinator.test(now: () => now);
    final auth = _FakeAuthProvider();
    final messages = _FakeMessageProvider();
    final context = await _pumpContext(tester, auth, messages);
    final visibleGate = Completer<void>();
    final visibleStarted = Completer<void>();
    coordinator.registerVisibleRefresh(() async {
      visibleStarted.complete();
      await visibleGate.future;
    });
    final replyVersion = ReplyNotificationState.instance.version;

    coordinator.onLifecycleChanged(context, AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 3));
    coordinator.onLifecycleChanged(context, AppLifecycleState.resumed);
    await visibleStarted.future;
    final refresh = coordinator.debugRunningRefresh!;

    auth.switchAccount(2);
    visibleGate.complete();
    await refresh;

    expect(auth.refreshUserCalls, 0);
    expect(ReplyNotificationState.instance.version, replyVersion);
  });

  testWidgets('恢复同步在上一轮未完成时不会重复启动', (tester) async {
    var now = DateTime(2026, 8, 24, 10);
    final coordinator = AppResumeCoordinator.test(now: () => now);
    final auth = _FakeAuthProvider();
    final messages = _FakeMessageProvider()..gate = Completer<void>();
    final context = await _pumpContext(tester, auth, messages);

    coordinator.onLifecycleChanged(context, AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 20));
    coordinator.onLifecycleChanged(context, AppLifecycleState.resumed);
    await messages.started.future;
    final refresh = coordinator.debugRunningRefresh!;

    coordinator.onLifecycleChanged(context, AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 20));
    coordinator.onLifecycleChanged(context, AppLifecycleState.resumed);
    expect(messages.loadCalls, 1);

    messages.gate!.complete();
    await refresh;
  });
}
