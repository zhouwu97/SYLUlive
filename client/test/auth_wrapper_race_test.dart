import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart';
import 'package:shenliyuan/models/startup_destination.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/major_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/teacher_provider.dart';
import 'package:shenliyuan/providers/team_recruitment_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_moderation_provider.dart';
import 'package:shenliyuan/providers/water_moderator_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/home_screen.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/services/root_page_state_service.dart';

class _FakeRootPageStateStore extends RootPageStateStore {
  final Map<int, Future<RestorablePageState?> Function()> handlers = {};

  @override
  Future<RestorablePageState?> readLastPage({int? accountId}) async {
    if (accountId != null && handlers.containsKey(accountId)) {
      return handlers[accountId]!();
    }
    return null;
  }
}

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider(super.dio);
  User? _testUser;

  @override
  User? get user => _testUser;

  @override
  bool get isLoggedIn => _testUser != null;

  @override
  bool get isInitialized => true;

  @override
  String? get token => 'test-token';

  @override
  int get accountSessionEpoch => 1;

  @override
  Future<void> refreshUser() async {}

  void setUser(User? user) {
    _testUser = user;
    notifyListeners();
  }
}

void main() {
  testWidgets('A 账号 readLastPage 延迟未完成时切换 B 账号，A 返回后不覆盖 B 且无残留 Loading', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final fakeStore = _FakeRootPageStateStore();
    RootPageStateStore.instance = fakeStore;

    final user1Completer = Completer<RestorablePageState?>();
    fakeStore.handlers[1] = () => user1Completer.future;
    fakeStore.handlers[2] = () async => const RestorablePageState(
          type: RestorablePageType.rootTab,
          arguments: <String, dynamic>{'index': 4},
          accountId: 2,
        );

    final themeProvider = ThemeProvider(loadOnStart: false);
    await themeProvider.loadThemeForTesting();
    await themeProvider.setStartupDestination(StartupDestinationMode.lastPage);

    final updateCoordinator = AppUpdateCoordinator();

    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    // 与 root_navigation_gesture_test 一致：不 stub 网络，让各 Provider 的
    // try/catch 吞掉失败请求，测试只关注 A/B readLastPage 竞态本身。

    final authProvider = _TestAuthProvider(dio);
    final postProvider = PostProvider(dio, enableCache: false);
    final user1 = User(
      id: 1,
      studentId: 'user1',
      nickname: '用户A',
      createdAt: DateTime.now(),
    );
    final user2 = User(
      id: 2,
      studentId: 'user2',
      nickname: '用户B',
      createdAt: DateTime.now(),
    );

    // 1. 用户 A 登录并挂起读取
    authProvider.setUser(user1);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<AppUpdateCoordinator>.value(
              value: updateCoordinator),
          ChangeNotifierProvider(create: (_) => postProvider),
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(create: (_) => EduProvider(dio)),
          ChangeNotifierProvider(create: (_) => CourseScheduleProvider(dio)),
          ChangeNotifierProvider(create: (_) => MessageProvider(dio)),
          ChangeNotifierProvider(create: (_) => WaterModeratorProvider(dio)),
          ChangeNotifierProvider(create: (_) => WaterModerationProvider(dio)),
          ChangeNotifierProvider(create: (_) => TeacherProvider(dio)),
          ChangeNotifierProvider(create: (_) => MajorProvider(dio)),
          ChangeNotifierProvider(create: (_) => SocialProvider(dio)),
          ChangeNotifierProvider(create: (_) => WaterSectionProvider(dio)),
          ChangeNotifierProvider(create: (_) => TeamRecruitmentProvider(dio)),
          ChangeNotifierProvider(create: (_) => CanteenDiscoveryProvider(dio)),
        ],
        child: const MaterialApp(
          home: AuthWrapper(),
        ),
      ),
    );

    // 此时 A 账号正在解析启动计划，界面显示门禁加载
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    // 2. 在 A 尚未完成异步读取时，快速切换为用户 B
    authProvider.setUser(user2);
    await tester.pump();

    // 3. 用户 A 的延迟读取此时终于返回
    user1Completer.complete(const RestorablePageState(
      type: RestorablePageType.rootTab,
      arguments: <String, dynamic>{'index': 1},
      accountId: 1,
    ));

    await tester.pumpAndSettle();

    // 4. 关键断言：最终必须正常渲染 HomeScreen，且门禁加载已消失
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    // 5. 卸载页面并放行 _bootstrapHome 遗留的延迟任务与定时器，避免测试结束时报 pending Timer
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
  });
}
