import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/screens/home_screen.dart';
import 'package:shenliyuan/services/app_update_coordinator.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

import 'helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('空课程只有在 ready 且完成初始化后才进入 empty', () {
    ScheduleViewState resolve({
      bool eduStatusLoaded = true,
      bool eduBound = true,
      ScheduleSessionPhase phase = ScheduleSessionPhase.ready,
      bool isLoading = false,
      bool isInitializing = false,
      bool hasCourses = false,
      bool hasSemesterStart = false,
    }) {
      return resolveScheduleViewState(
        eduStatusLoaded: eduStatusLoaded,
        eduBound: eduBound,
        sessionPhase: phase,
        isLoading: isLoading,
        isInitializing: isInitializing,
        hasCourses: hasCourses,
        hasSemesterStart: hasSemesterStart,
      );
    }

    expect(
      resolve(
        eduStatusLoaded: false,
        eduBound: false,
        phase: ScheduleSessionPhase.resolvingIdentity,
      ),
      ScheduleViewState.restoring,
    );
    expect(
      resolve(phase: ScheduleSessionPhase.restoringCache),
      ScheduleViewState.restoring,
    );
    expect(resolve(isLoading: true), ScheduleViewState.restoring);
    expect(resolve(isInitializing: true), ScheduleViewState.restoring);
    expect(resolve(), ScheduleViewState.empty);
    expect(
      resolve(hasCourses: true, hasSemesterStart: true),
      ScheduleViewState.ready,
    );
  });

  testWidgets('课表作为首屏时，Edu 身份和缓存延迟恢复期间不误显示空态，最终无需切 Tab 显示课程', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const reminderChannel = MethodChannel('shenliyuan/course_reminders');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(reminderChannel, null);
    });

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final data = options.path.contains('unread-count')
              ? <String, dynamic>{'count': 0, 'has_urgent': false}
              : options.path == '/posts'
                  ? <String, dynamic>{
                      'posts': <dynamic>[],
                      'pinned_posts': <dynamic>[],
                      'total': 0,
                    }
                  : <dynamic>[];
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );

    final auth = _LoggedInAuthProvider(client: dio);
    final edu = _DelayedEduProvider();
    final storeOpenRelease = Completer<void>();
    final cacheRelease = Completer<void>();
    final schedule = _DelayedCourseScheduleProvider(
      dio: dio,
      snapshotStore: YieldingPersonalSnapshotStore(),
      storeOpenRelease: storeOpenRelease.future,
      cacheRelease: cacheRelease.future,
    );
    final postProvider = PostProvider(dio, enableCache: false);
    final messageProvider = _TestMessageProvider();
    final themeProvider = ThemeProvider(loadOnStart: false);
    final updateCoordinator = _TestUpdateCoordinator();

    final widget = MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<EduProvider>.value(value: edu),
        ChangeNotifierProxyProvider2<AuthProvider, EduProvider,
            CourseScheduleProvider>(
          create: (_) => schedule,
          update: (_, auth, edu, provider) => provider!
            ..syncSessionContext(
              auth.user?.id.toString(),
              edu.studentId,
            ),
        ),
        ChangeNotifierProvider<PostProvider>.value(value: postProvider),
        ChangeNotifierProvider<MessageProvider>.value(value: messageProvider),
        ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ChangeNotifierProvider<AppUpdateCoordinator>.value(
          value: updateCoordinator,
        ),
      ],
      child: const MaterialApp(
        home: HomeScreen(initialTab: 2),
      ),
    );

    await tester.pumpWidget(widget);
    _expectNoScheduleEmptyState(tester);

    // 此时 Edu 状态尚未恢复，课表页必须保持恢复态。
    await _pumpAndExpectNoScheduleEmptyState(tester);

    // 先恢复“已绑定”结论，但故意让来源学号继续缺失。
    edu.restoreStatus(bound: true);
    await _pumpAndExpectNoScheduleEmptyState(tester);

    // 来源学号到达后，课表 Provider 才能打开对应的账号保险箱。
    edu.restoreStudentId('edu-1');
    for (var i = 0; i < 4 && !schedule.storeOpenStarted.isCompleted; i++) {
      await _pumpAndExpectNoScheduleEmptyState(tester);
    }
    expect(schedule.storeOpenStarted.isCompleted, isTrue);
    expect(schedule.cacheReadStarted.isCompleted, isFalse);
    _expectNoScheduleEmptyState(tester);

    // 保险箱打开完成后，继续阻塞缓存读取，覆盖“Store 已打开但快照尚未返回”。
    storeOpenRelease.complete();
    for (var i = 0; i < 8 && !schedule.cacheReadStarted.isCompleted; i++) {
      await _pumpAndExpectNoScheduleEmptyState(tester);
    }
    expect(schedule.cacheReadStarted.isCompleted, isTrue);
    _expectNoScheduleEmptyState(tester);

    // 释放延迟缓存读取；Provider 会先写入课程，再将 session 标记为 ready。
    cacheRelease.complete();
    for (var i = 0; i < 12 && find.text('线性代数').evaluate().isEmpty; i++) {
      await _pumpAndExpectNoScheduleEmptyState(
        tester,
        const Duration(milliseconds: 20),
      );
    }

    expect(find.text('还没有课表'), findsNothing);
    expect(find.text('线性代数'), findsOneWidget);
    expect(
      tester
          .widget<HomeTabKeepAliveStage>(find.byType(HomeTabKeepAliveStage))
          .index,
      2,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    auth.dispose();
    edu.dispose();
    postProvider.dispose();
    messageProvider.dispose();
    themeProvider.dispose();
    updateCoordinator.dispose();
    // ProxyProvider 会负责释放 schedule；这里不再手动 dispose，避免重复释放。
  });
}

void _expectNoScheduleEmptyState(WidgetTester tester) {
  expect(find.text('还没有课表'), findsNothing);
}

Future<void> _pumpAndExpectNoScheduleEmptyState(
  WidgetTester tester, [
  Duration duration = const Duration(milliseconds: 1),
]) async {
  await tester.pump(duration);
  _expectNoScheduleEmptyState(tester);
}

class _LoggedInAuthProvider extends ChangeNotifier implements AuthProvider {
  _LoggedInAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user => User(
        id: 1,
        studentId: 'app-user-1',
        nickname: '测试用户',
        createdAt: DateTime(2026),
      );

  @override
  String? get token => 'test-token';

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 0;

  @override
  int get accountSessionEpoch => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DelayedEduProvider extends EduProvider {
  _DelayedEduProvider() : super(Dio());

  bool _statusLoaded = false;
  bool _bound = false;
  String _studentId = '';

  @override
  bool get isStatusLoaded => _statusLoaded;

  @override
  bool get isBound => _bound;

  @override
  String get studentId => _studentId;

  void restoreStatus({required bool bound}) {
    _statusLoaded = true;
    _bound = bound;
    notifyListeners();
  }

  void restoreStudentId(String studentId) {
    _studentId = studentId;
    notifyListeners();
  }
}

class _DelayedCourseScheduleProvider extends CourseScheduleProvider {
  _DelayedCourseScheduleProvider({
    required Dio dio,
    required AccountScopedSnapshotStore snapshotStore,
    required this.storeOpenRelease,
    required this.cacheRelease,
  }) : super(dio, (_) => snapshotStore);

  final Future<void> storeOpenRelease;
  final Future<void> cacheRelease;
  final Completer<void> storeOpenStarted = Completer<void>();
  final Completer<void> cacheReadStarted = Completer<void>();
  bool _coursesInjected = false;
  bool _storeOpenReleased = false;
  Future<void>? _storeOpenFuture;

  @override
  void syncSessionContext(String? userId, String? sourceAccountId) {
    final normalizedUserId = userId?.trim() ?? '';
    final normalizedSourceAccountId = sourceAccountId?.trim() ?? '';
    if (normalizedUserId.isNotEmpty &&
        normalizedSourceAccountId.isNotEmpty &&
        !_storeOpenReleased) {
      if (_storeOpenFuture == null) {
        storeOpenStarted.complete();
        _storeOpenFuture = _openStoreAfterDelay(
          normalizedUserId,
          normalizedSourceAccountId,
        );
      }
      return;
    }
    super.syncSessionContext(userId, sourceAccountId);
  }

  Future<void> _openStoreAfterDelay(
    String userId,
    String sourceAccountId,
  ) async {
    await storeOpenRelease;
    _storeOpenReleased = true;
    super.syncSessionContext(userId, sourceAccountId);
  }

  @override
  Future<bool> loadCachedCoursesIfAvailable() async {
    if (!cacheReadStarted.isCompleted) cacheReadStarted.complete();
    await cacheRelease;
    if (_coursesInjected) return true;

    _coursesInjected = true;
    final count = await applyFetchedCourses([
      {
        'name': '线性代数',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1],
      },
    ]);
    await setSemesterStart(DateTime.now());
    return count > 0;
  }
}

class _TestMessageProvider extends MessageProvider {
  _TestMessageProvider() : super(Dio(), enableRealtime: false);

  @override
  Future<void> loadConversations({bool silent = false}) async {}
}

class _TestUpdateCoordinator extends AppUpdateCoordinator {
  @override
  Future<void> startDeferredInitialCheck() async {}
}
