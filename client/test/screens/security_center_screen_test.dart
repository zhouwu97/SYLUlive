import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/account_security_screen.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'package:shenliyuan/screens/admin_security_blocks_screen.dart';
import 'package:shenliyuan/screens/admin_security_center_screen.dart';
import 'package:shenliyuan/screens/admin_panel_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends AuthProvider {
  _Auth(this.requests) : super(Dio(), loadStoredAuth: false);
  final Dio requests;
  User? current = _user(7, 'super_admin');
  int epoch = 1;
  int passwordCalls = 0;
  int emailCalls = 0;
  int updateEmailCalls = 0;
  int removeEmailCalls = 0;
  String? boundEmail;
  Completer<AuthResult>? operation;
  @override
  User? get user => current;
  @override
  bool get isLoggedIn => current != null;
  @override
  int get accountSessionEpoch => epoch;
  @override
  Dio get dio => requests;
  void switchTo(int? id, {String role = 'user'}) {
    current = id == null ? null : _user(id, role);
    epoch++;
    notifyListeners();
  }

  void changeRole(String role) {
    current = _user(current!.id, role);
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>?> getAccountSecurity() async {
    try {
      return Map<String, dynamic>.from(
          (await requests.get('/user/account-security')).data as Map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) {
    passwordCalls++;
    return operation?.future ?? Future.value(AuthResult.success());
  }

  @override
  Future<AuthResult> requestUserEmailCode(String email) {
    emailCalls++;
    return operation?.future ?? Future.value(AuthResult.success());
  }

  @override
  Future<AuthResult> updateUserEmail(
      {required String email,
      required String code,
      required String password}) async {
    updateEmailCalls++;
    final result =
        await (operation?.future ?? Future.value(AuthResult.success()));
    if (result.success) boundEmail = email;
    return result;
  }

  @override
  Future<AuthResult> removeUserEmail(String password) async {
    removeEmailCalls++;
    final result =
        await (operation?.future ?? Future.value(AuthResult.success()));
    if (result.success) boundEmail = null;
    return result;
  }
}

User _user(int id, String role) => User(
    id: id,
    studentId: '',
    nickname: '验收用户$id',
    loginAccount: 'ACCOUNT-$id',
    role: role,
    createdAt: DateTime(2026));

Map<String, dynamic> _event(int id) => {
      'id': id,
      'event_type': 'login_bruteforce',
      'severity': 'high',
      'status': 'active',
      'route': '/api/login',
      'method': 'POST',
      'source_fingerprint': '测试来源',
      'source_key': 'synthetic-source-key',
      'target_masked': '验收目标$id',
      'target_type': 'account',
      'attempt_count': 12,
      'blocked_count': 9,
      'last_seen_at': '2026-10-19T08:00:00Z',
    };

class _Fixture {
  final dio = Dio();
  late final auth = _Auth(dio);
  final requests = <RequestOptions>[];
  FutureOr<Object> Function(RequestOptions)? respond;
  _Fixture() {
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      requests.add(options);
      try {
        final data = await Future<Object>.value(
            respond?.call(options) ?? defaults(options));
        handler.resolve(
            Response(requestOptions: options, data: data, statusCode: 200));
      } catch (_) {
        handler.reject(DioException(
            requestOptions: options,
            response: Response(
                requestOptions: options,
                statusCode: 503,
                data: {'error': '安全数据加载失败，请稍后重试'}),
            type: DioExceptionType.badResponse));
      }
    }));
  }
  Object defaults(RequestOptions options) => switch (options.path) {
        '/user/account-security' => {
            'login_account': 'ACCOUNT-${auth.user?.id}',
            'login_methods': ['student_id'],
            'email_bound': auth.boundEmail != null,
            'email': auth.boundEmail,
          },
        '/admin/security/overview' => {
            'range': '24h',
            'actionable_high_count': 3,
            'blocked_requests': 9,
            'affected_targets': 2,
            'unique_sources': 1,
            'protection': {
              'security_block': 'disabled',
              'security_event_collection': 'healthy',
              'security_alerts': 'not_configured'
            }
          },
        '/admin/security/events' => {
            'items': [_event(1)],
            'total': 1,
            'limit': 50
          },
        '/super/security/blocks' => [
            {
              'id': 8,
              'group_id': 'qa',
              'source_fingerprint': '验收封禁来源',
              'route_prefix': '/api/login',
              'reason': '验收记录',
              'expires_at': '2099-01-01T00:00:00Z',
              'created_by': 7
            }
          ],
        _ => {'message': '成功'},
      };
}

final _captureKey = GlobalKey();
Future<void> _pump(WidgetTester tester, _Fixture fixture, Widget screen,
    {ThemeMode theme = ThemeMode.light,
    double scale = 1,
    bool settle = true}) async {
  final preferences = ThemeProvider();
  final repo = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: JiaowuLocalDataSource(),
      source: AcademicSourceKind.local);
  final academic = AcademicSessionController(repository: repo);
  addTearDown(() {
    fixture.auth.dispose();
    fixture.dio.close();
    preferences.dispose();
    academic.dispose();
    repo.close();
  });
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: fixture.auth),
        ChangeNotifierProvider<ThemeProvider>.value(value: preferences),
        ChangeNotifierProvider<AcademicSessionController>.value(
            value: academic),
      ],
      child: RepaintBoundary(
          key: _captureKey,
          child: GoldenTestApp(
              themeMode: theme,
              textScaler: TextScaler.linear(scale),
              home: screen))));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['SECURITY_QA_DIR'];
  if (directory == null) return;
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final pixels = await boundary.toImage(pixelRatio: 1);
    final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    pixels.dispose();
  });
}

Future<void> _scrollTo(WidgetTester tester, Finder target, double delta) async {
  await tester.scrollUntilVisible(target, delta,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in [
    (name: 'light', theme: ThemeMode.light, scale: 1.0),
    (name: 'dark', theme: ThemeMode.dark, scale: 1.0),
    (name: 'large', theme: ThemeMode.light, scale: 1.3),
    (name: 'stress', theme: ThemeMode.dark, scale: 1.5),
  ]) {
    testWidgets('安全中心界面渲染 ${profile.name}', (tester) async {
      final f = _Fixture();
      await _pump(tester, f, const AdminSecurityCenterScreen(),
          theme: profile.theme, scale: profile.scale);
      expect(find.text('高危待处理'), findsOneWidget);
      expect(find.text('未验证'), findsWidgets);
      await _capture(tester, 'admin-${profile.name}');
      await _scrollTo(tester, find.text('目标：验收目标1'), 400);
      await tester.tap(find.text('目标：验收目标1'));
      await tester.pumpAndSettle();
      await _capture(tester, 'event-${profile.name}');
      expect(tester.getSize(find.widgetWithText(FilledButton, '标记已处理')).height,
          greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    });
    testWidgets('账号安全表单界面渲染 ${profile.name}', (tester) async {
      final f = _Fixture();
      await _pump(tester, f, const AccountSecurityScreen(),
          theme: profile.theme, scale: profile.scale);
      await _capture(tester, 'account-${profile.name}');
      await _scrollTo(tester, find.text('修改 APP 密码'), 250);
      await tester.tap(find.text('修改 APP 密码'));
      await tester.pumpAndSettle();
      expect(find.byType(AppAlertDialog), findsOneWidget);
      expect(tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(44));
      await _capture(tester, 'password-${profile.name}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('私有资料加载失败明确错误并可以重试', (tester) async {
    final f = _Fixture()..respond = (_) => throw StateError('离线');
    await _pump(tester, f, const AccountSecurityScreen());
    expect(find.text('账号安全信息加载失败，请重试'), findsOneWidget);
    expect(find.text('邮箱未绑定'), findsNothing);
    f.respond = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('App 登录账号：ACCOUNT-7'), findsOneWidget);
  });

  testWidgets('邮箱验证码校验、发送冷却与关闭恢复', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AccountSecurityScreen());
    await _scrollTo(tester, find.text('邮箱未绑定'), 250);
    await tester.tap(find.text('邮箱未绑定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(f.auth.emailCalls, 0);
    expect(find.text('请输入有效邮箱'), findsWidgets);
    await tester.enterText(
        find.byType(TextFormField).at(0), 'synthetic@example.test');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(f.auth.emailCalls, 1);
    expect(find.textContaining('秒后重试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(f.auth.emailCalls, 2);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('账号切换后迟到的完整邮箱不能出现在新账号页面', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AccountSecurityScreen());
    final old = Completer<Object>();
    f.respond = (r) => f.auth.user?.id == 7 ? old.future : f.defaults(r);
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pump(const Duration(milliseconds: 500));
    f.auth.switchTo(8);
    await tester.pump(const Duration(milliseconds: 500));
    old.complete({'email': 'private-old@example.test', 'email_bound': true});
    await refresh;
    await tester.pumpAndSettle();
    expect(find.textContaining('private-old'), findsNothing);
    expect(find.text('App 登录账号：ACCOUNT-8'), findsOneWidget);
  });

  for (final screen in [
    const AdminPanelScreen(),
    const AdminSecurityCenterScreen(),
    const AdminSecurityBlocksScreen()
  ]) {
    testWidgets('普通用户直接进入 ${screen.runtimeType} 不发管理请求', (tester) async {
      final f = _Fixture();
      f.auth.switchTo(9);
      await _pump(tester, f, screen);
      expect(f.requests, isEmpty);
      expect(find.textContaining('权限'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  }

  testWidgets('刷新失败移除旧防护状态，允许重新加载', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AdminSecurityCenterScreen());
    expect(find.text('防护状态'), findsOneWidget);
    f.respond = (_) => throw StateError('暂时不可用');
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('防护状态'), findsNothing);
    expect(find.text('安全数据加载失败，请稍后重试'), findsOneWidget);
    await _capture(tester, 'admin-error');
    f.respond = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('防护状态'), findsOneWidget);
  });

  testWidgets('超级管理员详情降权后隐藏来源键和封禁入口', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AdminSecurityCenterScreen());
    await _scrollTo(tester, find.text('目标：验收目标1'), 400);
    await tester.tap(find.text('目标：验收目标1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic-source-key'), findsOneWidget);
    f.auth.changeRole('admin');
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic-source-key'), findsNothing);
    expect(find.text('临时封禁来源'), findsNothing);
  });

  testWidgets('改密提交锁定重复点击，失败后保留输入允许重试', (tester) async {
    final f = _Fixture();
    f.auth.operation = Completer<AuthResult>();
    await _pump(tester, f, const AccountSecurityScreen());
    await _scrollTo(tester, find.text('修改 APP 密码'), 300);
    await tester.tap(find.text('修改 APP 密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'old-password');
    await tester.enterText(find.byType(TextFormField).at(1), 'new-password');
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pump();
    expect(f.auth.passwordCalls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    f.auth.operation!.complete(AuthResult.failure('当前密码错误'));
    await tester.pumpAndSettle();
    expect(find.text('当前密码错误'), findsOneWidget);
    f.auth.operation = null;
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(f.auth.passwordCalls, 2);
    expect(find.byType(AppAlertDialog), findsNothing);
  });

  testWidgets('事件弹层切换账号隐藏旧信息并禁止旧处置', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AdminSecurityCenterScreen());
    await _scrollTo(tester, find.text('目标：验收目标1'), 400);
    await tester.tap(find.text('目标：验收目标1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记已处理').last);
    await tester.pumpAndSettle();
    f.auth.switchTo(8, role: 'admin');
    await tester.pumpAndSettle();
    expect(find.text('登录状态或权限已变化'), findsOneWidget);
    expect(find.text('确认'), findsNothing);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets('封禁确认后降权不能继续操作或展示旧封禁', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AdminSecurityBlocksScreen());
    await tester.tap(find.text('解除封禁'));
    await tester.pumpAndSettle();
    f.auth.changeRole('admin');
    await tester.pumpAndSettle();
    expect(find.text('确认解除'), findsNothing);
    expect(find.textContaining('验收封禁来源'), findsNothing);
    expect(f.requests.where((r) => r.method == 'DELETE'), isEmpty);
  });

  testWidgets('事件分页失败可重试，筛选后丢弃旧页且不串列表', (tester) async {
    final f = _Fixture();
    var failPage = true;
    f.respond = (r) {
      if (r.path != '/admin/security/events') return f.defaults(r);
      if (r.queryParameters['severity'] == 'high') {
        return {
          'items': [_event(9)],
          'total': 1,
          'limit': 50
        };
      }
      if (r.queryParameters['page'] == 2) {
        if (failPage) throw StateError('第二页离线');
        return {
          'items': [_event(2)],
          'total': 2,
          'limit': 1
        };
      }
      return {
        'items': [_event(1)],
        'total': 2,
        'limit': 1
      };
    };
    await _pump(tester, f, const AdminSecurityCenterScreen());
    await _scrollTo(tester, find.text('加载更多'), 400);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('加载更多失败，请重试'), findsOneWidget);
    failPage = false;
    await tester.tap(find.text('重试加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('目标：验收目标2'), findsOneWidget);
    await _scrollTo(tester, find.widgetWithText(ChoiceChip, '高危'), -300);
    await tester.tap(find.widgetWithText(ChoiceChip, '高危'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('目标：验收目标9'), 200);
    expect(find.text('目标：验收目标2'), findsNothing);
  });

  testWidgets('翻页未完成时切换筛选，迟到的旧页不能回填', (tester) async {
    final f = _Fixture();
    final oldPage = Completer<Object>();
    f.respond = (r) {
      if (r.path != '/admin/security/events') return f.defaults(r);
      if (r.queryParameters['severity'] == 'high') {
        return {
          'items': [_event(9)],
          'total': 1,
          'limit': 50
        };
      }
      if (r.queryParameters['page'] == 2) return oldPage.future;
      return {
        'items': [_event(1)],
        'total': 2,
        'limit': 1
      };
    };
    await _pump(tester, f, const AdminSecurityCenterScreen());
    await _scrollTo(tester, find.text('加载更多'), 400);
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    await _scrollTo(tester, find.widgetWithText(ChoiceChip, '高危'), -300);
    await tester.tap(find.widgetWithText(ChoiceChip, '高危'));
    await tester.pumpAndSettle();
    oldPage.complete({
      'items': [_event(2)],
      'total': 2,
      'limit': 1
    });
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('目标：验收目标9'), 250);
    expect(find.text('目标：验收目标2'), findsNothing);
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('改密表单校验长度与数字验证码，旧弹层切号不可提交', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AccountSecurityScreen());
    await _scrollTo(tester, find.text('修改 APP 密码'), 300);
    await tester.tap(find.text('修改 APP 密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), 'x' * 33);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(find.text('请输入当前密码'), findsOneWidget);
    expect(find.text('请输入 8–32 位密码'), findsOneWidget);
    expect(f.auth.passwordCalls, 0);
    f.auth.switchTo(8);
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('登录状态或权限已变化'), findsOneWidget);
    expect(f.auth.passwordCalls, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('邮箱未绑定'), -200);
    await tester.tap(find.text('邮箱未绑定'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'synthetic@example.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'abcdef');
    await tester.enterText(
        find.byType(TextFormField).at(2), 'synthetic-password');
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 6 位数字验证码'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('窄屏大字与键盘下邮箱表单仍可输入及取消', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AccountSecurityScreen(),
        theme: ThemeMode.dark, scale: 1.5);
    await _scrollTo(tester, find.text('邮箱未绑定'), 300);
    await tester.tap(find.text('邮箱未绑定'));
    await tester.pumpAndSettle();
    tester.view.viewInsets =
        FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'synthetic@example.test');
    await tester.ensureVisible(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    await _capture(tester, 'email-keyboard-stress');
    expect(tester.getRect(find.widgetWithText(FilledButton, '确认')).bottom,
        lessThanOrEqualTo(500));
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AppAlertDialog), findsNothing);
  });

  testWidgets('管理面板切号后仅显示新账号安全计数', (tester) async {
    final f = _Fixture();
    final old = Completer<Object>();
    f.respond = (r) {
      if (f.auth.user?.id == 7) return old.future;
      if (r.path == '/admin/security/overview') {
        return {'actionable_high_count': 42};
      }
      return <String, dynamic>{'items': []};
    };
    await _pump(tester, f, const AdminPanelScreen(), settle: false);
    f.auth.switchTo(8, role: 'admin');
    await tester.pumpAndSettle();
    old.complete({'actionable_high_count': 77, 'items': []});
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('42'), 400);
    expect(find.text('77'), findsNothing);
    final requests =
        f.requests.where((r) => r.path == '/admin/security/overview');
    expect(requests.map((r) => r.extra['expectedAuthUserId']),
        containsAll([7, 8]));
  });

  testWidgets('邮箱绑定与解绑提交中锁定，失败保留输入并可恢复', (tester) async {
    final f = _Fixture();
    await _pump(tester, f, const AccountSecurityScreen());
    await _scrollTo(tester, find.text('邮箱未绑定'), 250);
    await tester.tap(find.text('邮箱未绑定'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextFormField).at(0), 'synthetic@example.test');
    await tester.enterText(find.byType(TextFormField).at(1), '123456');
    await tester.enterText(
        find.byType(TextFormField).at(2), 'synthetic-password');
    f.auth.operation = Completer<AuthResult>();
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pump();
    expect(f.auth.updateEmailCalls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    f.auth.operation!.complete(AuthResult.failure('验证码错误'));
    await tester.pumpAndSettle();
    expect(find.text('验证码错误'), findsOneWidget);
    f.auth.operation = null;
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(f.auth.updateEmailCalls, 2);
    await _scrollTo(tester, find.text('解除邮箱'), 200);
    await tester.tap(find.text('解除邮箱'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'synthetic-password');
    f.auth.operation = Completer<AuthResult>();
    await tester.tap(find.widgetWithText(FilledButton, '解除'));
    await tester.pump();
    expect(f.auth.removeEmailCalls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    f.auth.operation!.complete(AuthResult.failure('解除失败，请重试'));
    await tester.pumpAndSettle();
    expect(find.text('解除失败，请重试'), findsOneWidget);
    f.auth.operation = null;
    await tester.tap(find.widgetWithText(FilledButton, '解除'));
    await tester.pumpAndSettle();
    expect(f.auth.removeEmailCalls, 2);
    await _scrollTo(tester, find.text('邮箱未绑定'), 200);
    expect(find.text('邮箱未绑定'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
