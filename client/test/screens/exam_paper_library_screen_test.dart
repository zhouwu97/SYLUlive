import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/exam_papers/exam_paper_library_screen.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this.fakeUser) : super(Dio());

  User fakeUser;
  final Dio fakeDio = Dio();

  @override
  User? get user => fakeUser;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isInitialized => true;

  @override
  Dio get dio => fakeDio;

  @override
  Future<void> refreshUser() async {}
}

class _RefreshingAuth extends _FakeAuthProvider {
  _RefreshingAuth(super.fakeUser, this.refresh);
  final Future<void> Function(_RefreshingAuth) refresh;
  int refreshes = 0;
  int _profileGeneration = 7;
  int _accountEpoch = 1;

  @override
  int get sessionGeneration => _profileGeneration;

  @override
  int get accountSessionEpoch => _accountEpoch;

  void useAccount(User user) {
    fakeUser = user;
    _accountEpoch++;
    _profileGeneration++;
    notifyListeners();
  }

  @override
  Future<void> refreshUser() async {
    refreshes++;
    await refresh(this);
    _profileGeneration++;
    notifyListeners();
  }
}

class _BindingCoordinator {
  _BindingCoordinator(this.sync);
  final Future<String?> Function() sync;
  int synchronizations = 0;
  Future<String?> synchronizeIdentityBinding({bool force = true}) {
    synchronizations++;
    return sync();
  }
}

class _SwitchableAuthProvider extends _FakeAuthProvider {
  _SwitchableAuthProvider(super.fakeUser);

  int _generation = 7;

  @override
  int get sessionGeneration => _generation;

  void rotateSession() {
    _generation++;
    notifyListeners();
  }
}

class _FakeExamPaperService extends ExamPaperService {
  _FakeExamPaperService() : super(Dio());

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    return ExamPaperPage(
      items: [_paper(1, '高等数学')],
      page: page,
      pageSize: pageSize,
      total: 128,
    );
  }
}

class _RefreshFailingExamPaperService extends ExamPaperService {
  _RefreshFailingExamPaperService() : super(Dio());

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    if (keyword.isEmpty) {
      return ExamPaperPage(
        items: [_paper(1, '高等数学')],
        page: 1,
        pageSize: 20,
        total: 1,
      );
    }
    throw const ExamPaperApiException(
      message: '刷新失败，请重试',
      code: 'network_error',
    );
  }
}

class _EmptyExamPaperService extends ExamPaperService {
  _EmptyExamPaperService() : super(Dio());

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    return const ExamPaperPage(items: [], page: 1, pageSize: 20, total: 0);
  }
}

class _CapturingExamPaperService extends ExamPaperService {
  _CapturingExamPaperService() : super(Dio());

  String keyword = '';
  String academicYear = '';

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    this.keyword = keyword;
    this.academicYear = academicYear;
    return const ExamPaperPage(
      items: [],
      page: 1,
      pageSize: 20,
      total: 0,
      academicYears: ['2025-2026', '2024-2025'],
    );
  }
}

class _OutOfOrderExamPaperService extends ExamPaperService {
  _OutOfOrderExamPaperService() : super(Dio());

  final oldRequest = Completer<ExamPaperPage>();
  final newRequest = Completer<ExamPaperPage>();

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) {
    if (keyword == 'old') return oldRequest.future;
    if (keyword == 'new') return newRequest.future;
    return Future.value(
      const ExamPaperPage(items: [], page: 1, pageSize: 20, total: 0),
    );
  }
}

class _DelayedRefreshExamPaperService extends ExamPaperService {
  _DelayedRefreshExamPaperService() : super(Dio());

  final refreshRequest = Completer<ExamPaperPage>();
  int filteredPageTwoCalls = 0;

  @override
  Future<ExamPaperPage> list({
    String keyword = '',
    String academicYear = '',
    String semester = '',
    String examType = '',
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) {
    if (keyword == '物理' && page == 1) return refreshRequest.future;
    if (keyword == '物理' && page == 2) {
      filteredPageTwoCalls++;
      return Future.value(
        ExamPaperPage(
          items: [_paper(100, '错误追加结果')],
          page: 2,
          pageSize: pageSize,
          total: 40,
        ),
      );
    }
    return Future.value(
      ExamPaperPage(
        items: List.generate(
          20,
          (index) => _paper(index + 1, '旧结果 ${index + 1}'),
        ),
        page: 1,
        pageSize: pageSize,
        total: 40,
      ),
    );
  }
}

void main() {
  User account({required bool verified}) => User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: verified,
      eduBound: false,
      createdAt: DateTime(2026));

  Future<void> openAccessCheck(WidgetTester tester, AuthProvider auth,
      {_BindingCoordinator? coordinator, bool settle = true}) async {
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(loadOnStart: false)),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
            home: ExamPaperLibraryScreen(
                service: _FakeExamPaperService(),
                synchronizeAcademicBinding: coordinator == null
                    ? null
                    : () => coordinator.synchronizeIdentityBinding()))));
    if (settle) {
      await tester.pumpAndSettle(const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    } else {
      await tester.pump();
    }
  }

  testWidgets('核对资格期间切号，旧账号完成不能解锁新账号试卷库', (tester) async {
    final waiting = Completer<void>();
    final started = Completer<void>();
    final auth = _RefreshingAuth(account(verified: false), (auth) async {
      if (auth.fakeUser.id == 1) {
        if (!started.isCompleted) started.complete();
        await waiting.future;
      }
    });
    await openAccessCheck(tester, auth, settle: false);
    await started.future;
    auth.useAccount(User(
        id: 2,
        studentId: '20260002',
        nickname: '另一账号',
        studentVerified: false,
        eduBound: false,
        createdAt: DateTime(2026)));
    await tester.pump();
    waiting.complete();
    await tester.pumpAndSettle();
    expect(find.text('高等数学'), findsNothing);
    expect(find.text('完成教务认证后使用'), findsOneWidget);
    expect(auth.user?.id, 2);
  });

  testWidgets('试卷库打开时刷新旧身份缓存，服务器已核验即可进入', (tester) async {
    final auth = _RefreshingAuth(account(verified: false), (auth) async {
      auth.fakeUser = account(verified: true);
    });
    await openAccessCheck(tester, auth);
    expect(auth.refreshes, 1);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('完成教务认证后使用'), findsNothing);
  });

  testWidgets('同一账号重新登录后不接收旧登录会话的补交结果', (tester) async {
    final waiting = Completer<String?>();
    final started = Completer<void>();
    final auth = _RefreshingAuth(account(verified: false), (_) async {});
    var attempts = 0;
    final coordinator = _BindingCoordinator(() async {
      if (++attempts == 1) {
        started.complete();
        return waiting.future;
      }
      return '当前登录会话暂未同步';
    });
    await openAccessCheck(tester, auth,
        coordinator: coordinator, settle: false);
    await started.future;
    auth.useAccount(account(verified: false));
    await tester.pump();
    waiting.complete('旧登录会话失败');
    await tester.pumpAndSettle();
    expect(coordinator.synchronizations, 2);
    expect(find.text('当前登录会话暂未同步'), findsOneWidget);
    expect(find.text('旧登录会话失败'), findsNothing);
    expect(find.text('正在同步已有教务绑定…'), findsNothing);
  });

  testWidgets('试卷库在服务器漏记时恢复本机会话并自动补交后刷新资格', (tester) async {
    var serverVerified = false;
    final auth = _RefreshingAuth(account(verified: false), (auth) async {
      auth.fakeUser = account(verified: serverVerified);
    });
    final coordinator = _BindingCoordinator(() async {
      serverVerified = true;
      return null;
    });
    await openAccessCheck(tester, auth, coordinator: coordinator);
    expect(coordinator.synchronizations, 1);
    expect(auth.refreshes, 2);
    expect(find.text('高等数学'), findsOneWidget);
  });

  testWidgets('试卷库补交失败展示实际原因并可重试，不把失败画成未绑定', (tester) async {
    var failed = true;
    var serverVerified = false;
    final auth = _RefreshingAuth(account(verified: false), (auth) async {
      auth.fakeUser = account(verified: serverVerified);
    });
    final coordinator = _BindingCoordinator(() async {
      if (failed) return '学校会话需要恢复，请在原教务入口重新登录';
      serverVerified = true;
      return null;
    });
    await openAccessCheck(tester, auth, coordinator: coordinator);
    expect(find.text('学校会话需要恢复，请在原教务入口重新登录'), findsOneWidget);
    expect(find.text('重试同步'), findsOneWidget);
    failed = false;
    await tester.tap(find.text('重试同步'));
    await tester.pumpAndSettle();
    expect(coordinator.synchronizations, 2);
    expect(find.text('高等数学'), findsOneWidget);
  });

  testWidgets('认证 generation 变化时重建生产试卷服务', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );
    final auth = _SwitchableAuthProvider(user);
    final createdScopes = <int>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(
            serviceFactory: (currentAuth) {
              createdScopes.add(currentAuth.sessionGeneration);
              return _FakeExamPaperService();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(createdScopes, [7]);

    auth.rotateSession();
    await tester.pumpAndSettle();

    expect(createdScopes, [7, 8]);
  });

  testWidgets('已认证用户看到搜索筛选、我的投稿和投稿入口', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(service: _FakeExamPaperService()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('试卷库'), findsOneWidget);
    expect(find.text('搜索课程名或关键词'), findsOneWidget);
    expect(find.byTooltip('我的投稿'), findsOneWidget);
    expect(find.text('投稿'), findsOneWidget);
    expect(find.text('共 128 份试卷'), findsOneWidget);
    expect(find.text('高等数学'), findsOneWidget);
  });

  testWidgets('搜索请求乱序返回时只展示最新关键词结果', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );
    final service = _OutOfOrderExamPaperService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.byType(TextField);
    await tester.enterText(search, 'old');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(search, 'new');
    await tester.pump(const Duration(milliseconds: 450));

    service.newRequest.complete(
      ExamPaperPage(
        items: [_paper(2, '最新结果')],
        page: 1,
        pageSize: 20,
        total: 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('最新结果'), findsOneWidget);

    service.oldRequest.complete(
      ExamPaperPage(
        items: [_paper(1, '过期结果')],
        page: 1,
        pageSize: 20,
        total: 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('最新结果'), findsOneWidget);
    expect(find.text('过期结果'), findsNothing);
  });

  testWidgets('刷新失败时保留已加载试卷并展示内联重试', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(
            service: _RefreshFailingExamPaperService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '物理');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('刷新失败，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('筛选首屏请求进行中不会加载新筛选的下一页', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );
    final service = _DelayedRefreshExamPaperService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(home: ExamPaperLibraryScreen(service: service)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '物理');
    await tester.pump(const Duration(milliseconds: 450));
    final list = tester.widget<ListView>(find.byType(ListView).last);
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pump();

    expect(service.filteredPageTwoCalls, 0);

    service.refreshRequest.complete(
      const ExamPaperPage(items: [], page: 1, pageSize: 20, total: 0),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('筛选无结果时可以清除条件或投稿', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(
          home: ExamPaperLibraryScreen(service: _EmptyExamPaperService()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '概率论');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    expect(find.text('没有找到匹配的试卷'), findsOneWidget);
    expect(find.text('清除筛选'), findsOneWidget);
    expect(find.text('投稿这门课试卷'), findsOneWidget);

    await tester.tap(find.text('投稿这门课试卷'));
    await tester.pumpAndSettle();
    expect(find.textContaining('概率论 ·'), findsOneWidget);
  });

  testWidgets('搜索框关闭图标只清除关键词并保留其他筛选', (tester) async {
    final user = User(
      id: 1,
      studentId: '20260001',
      nickname: '测试用户',
      studentVerified: true,
      eduBound: true,
      createdAt: DateTime(2026),
    );
    final service = _CapturingExamPaperService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(user),
          ),
        ],
        child: MaterialApp(home: ExamPaperLibraryScreen(service: service)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部学年'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025-2026').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '高数');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    expect(service.keyword, isEmpty);
    expect(service.academicYear, '2025-2026');
  });
}

ExamPaper _paper(int id, String title) {
  return ExamPaper.fromJson({
    'id': id,
    'status': 'published',
    'source': 'user',
    'course_name': title,
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': title,
    'file_size': 1024,
    'download_count': 0,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  });
}
