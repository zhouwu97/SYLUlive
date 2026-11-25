import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/physical_test_screen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';
import 'package:shenliyuan/screens/lottery_screen.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';

class _LotteryAuth extends ChangeNotifier implements AuthProvider {
  _LotteryAuth(this.dio, {this.role = 'user'});
  @override
  final Dio dio;
  int id = 1;
  final String role;
  @override
  int accountSessionEpoch = 1;
  @override
  bool get isLoggedIn => true;
  @override
  int get sessionGeneration => accountSessionEpoch;
  @override
  User get user => User(
      id: id,
      studentId: '',
      nickname: '合成账号$id',
      role: role,
      academicConfigured: true,
      createdAt: DateTime(2026));
  void switchAccount() {
    id++;
    accountSessionEpoch++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _currentLottery({bool due = false}) => {
      'event': {
        'id': 1,
        'title': '合成抽奖',
        'prize_name': '合成奖品',
        'status': 0,
        'draw_time':
            DateTime.now().add(Duration(days: due ? -1 : 1)).toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      },
      'joined': false,
      'academic_configured': true,
      'participant_count': 0,
    };

Future<void> _lotteryFrames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pumpLottery(WidgetTester tester, _LotteryAuth auth,
    {ThemeMode theme = ThemeMode.light,
    double scale = 1,
    GlobalKey? boundary}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
      value: auth,
      child: RepaintBoundary(
          key: boundary,
          child: GoldenTestApp(
              themeMode: theme,
              textScaler: TextScaler.linear(scale),
              home: const LotteryScreen()))));
  await _lotteryFrames(tester);
}

class _Auth extends AuthProvider {
  _Auth(this.fixtureUser) : super(Dio(), loadStoredAuth: false);
  final User fixtureUser;
  @override
  bool get isLoggedIn => true;
  @override
  User get user => fixtureUser;
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  for (final oldSuccess in [true, false]) {
    testWidgets('抽奖切号后旧报名不改写新账号或结束新提交 success=$oldSuccess', (tester) async {
      final dio = Dio();
      final auth = _LotteryAuth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      final joins = <(RequestOptions, RequestInterceptorHandler)>[];
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.path.endsWith('/join')) {
          joins.add((request, handler));
          return;
        }
        handler.resolve(Response(
            requestOptions: request,
            data: request.path.endsWith('/current')
                ? _currentLottery()
                : {'items': []}));
      }));
      await _pumpLottery(tester, auth);
      await tester.ensureVisible(find.text('立即参与'));
      await tester.tap(find.text('立即参与'));
      await _lotteryFrames(tester);
      expect(joins, hasLength(1));
      expect(joins[0].$1.extra, containsPair('expectedAuthUserId', 1));
      auth.switchAccount();
      await _lotteryFrames(tester);
      await tester.ensureVisible(find.text('立即参与'));
      await tester.tap(find.text('立即参与'));
      await _lotteryFrames(tester);
      expect(joins, hasLength(2));
      expect(joins[1].$1.extra, containsPair('expectedAuthUserId', 2));
      expect(joins[0].$1.headers['Idempotency-Key'],
          isNot(joins[1].$1.headers['Idempotency-Key']));
      if (oldSuccess) {
        joins[0].$2.resolve(
            Response(requestOptions: joins[0].$1, data: {'weight': 8}));
      } else {
        joins[0].$2.reject(DioException(
            requestOptions: joins[0].$1,
            response: Response(requestOptions: joins[0].$1, statusCode: 503)));
      }
      await _lotteryFrames(tester);
      expect(find.text('参与成功！'), findsNothing);
      expect(find.text('已参与'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      joins[1]
          .$2
          .resolve(Response(requestOptions: joins[1].$1, data: {'weight': 2}));
      await _lotteryFrames(tester);
      expect(find.text('参与成功！'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final (theme, scale) in [
    (ThemeMode.light, 1.0),
    (ThemeMode.dark, 1.0),
    (ThemeMode.dark, 1.8)
  ]) {
    testWidgets('抽奖历史失败可单独重试且空态可见 $theme $scale', (tester) async {
      final dio = Dio();
      final auth = _LotteryAuth(dio);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      var historyLoads = 0, currentLoads = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.path.endsWith('/current')) {
          currentLoads++;
          handler.resolve(
              Response(requestOptions: request, data: _currentLottery()));
        } else if (++historyLoads == 1) {
          handler.reject(DioException(
              requestOptions: request,
              response: Response(requestOptions: request, statusCode: 503)));
        } else {
          handler
              .resolve(Response(requestOptions: request, data: {'items': []}));
        }
      }));
      final boundary = GlobalKey();
      await _pumpLottery(tester, auth,
          theme: theme, scale: scale, boundary: boundary);
      final retry = find.text('重试加载往期记录');
      await tester.ensureVisible(retry);
      await _lotteryFrames(tester);
      expect(find.text('合成抽奖'), findsWidgets);
      final folder = Platform.environment['LOTTERY_UI_EVIDENCE'];
      if (folder != null) {
        await tester.runAsync(() async {
          await Directory(folder).create(recursive: true);
          final image = await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$folder/history-error-${theme.name}-$scale.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(retry);
      await _lotteryFrames(tester);
      expect(find.text('暂无往期记录'), findsOneWidget);
      expect(historyLoads, 2);
      expect(currentLoads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('抽奖旧历史错误不结束新账号历史加载', (tester) async {
    final dio = Dio();
    final auth = _LotteryAuth(dio);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final histories = <(RequestOptions, RequestInterceptorHandler)>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path.endsWith('/history')) {
        histories.add((request, handler));
        return;
      }
      handler
          .resolve(Response(requestOptions: request, data: _currentLottery()));
    }));
    await _pumpLottery(tester, auth);
    auth.switchAccount();
    await _lotteryFrames(tester);
    expect(histories, hasLength(2));
    histories[0].$2.reject(DioException(requestOptions: histories[0].$1));
    await _lotteryFrames(tester);
    expect(find.text('重试加载往期记录'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    histories[1].$2.resolve(
        Response(requestOptions: histories[1].$1, data: {'items': []}));
    await _lotteryFrames(tester);
    expect(find.text('暂无往期记录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final phase in ['confirmation', 'response']) {
    testWidgets('手动开奖切号后不沿用旧确认或旧结果 $phase', (tester) async {
      final dio = Dio();
      final auth = _LotteryAuth(dio, role: 'super_admin');
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      (RequestOptions, RequestInterceptorHandler)? pendingDraw;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.path.endsWith('/draw')) {
          pendingDraw = (request, handler);
          return;
        }
        handler.resolve(Response(
            requestOptions: request,
            data: request.path.endsWith('/current')
                ? _currentLottery(due: true)
                : {'items': []}));
      }));
      await _pumpLottery(tester, auth);
      final manual = find.widgetWithText(TextButton, '兜底手动补开');
      await tester.ensureVisible(manual);
      await tester.tap(manual);
      await _lotteryFrames(tester);
      if (phase == 'confirmation') auth.switchAccount();
      await tester.tap(find.text('确认开奖'));
      await _lotteryFrames(tester);
      if (phase == 'confirmation') {
        expect(pendingDraw, isNull);
      } else {
        expect(pendingDraw, isNotNull);
        expect(pendingDraw!.$1.extra, containsPair('expectedAuthUserId', 1));
        auth.switchAccount();
        await _lotteryFrames(tester);
        pendingDraw!.$2
            .resolve(Response(requestOptions: pendingDraw!.$1, data: {}));
        await _lotteryFrames(tester);
        expect(find.text('开奖成功！'), findsNothing);
      }
      expect(tester.widget<TextButton>(manual).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final saved in [true, false]) {
    testWidgets('体测保存密码后自动打开查询，未保存时等待输入：saved=$saved', (tester) async {
      AppPreferencesStore.setMockInitialValues({});
      const password = '@Fixture0+&=%•';
      FlutterSecureStorage.setMockInitialValues({
        if (saved) 'secure_physical_test_pwd_20260001': password,
      });
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false)),
        ChangeNotifierProvider<AuthProvider>(
            create: (_) => _Auth(User(
                id: 1,
                studentId: '20260001',
                nickname: '测试',
                createdAt: DateTime(2026)))),
      ], child: const MaterialApp(home: ToolboxScreen())));
      await tester.tap(find.text('体测成绩'));
      await tester.pumpAndSettle();
      if (saved) {
        expect(
            tester
                .widget<PhysicalTestPage>(find.byType(PhysicalTestPage))
                .password,
            password);
        await tester.tap(find.text('返回修改密码'));
        await tester.pumpAndSettle();
        expect(find.byType(PhysicalTestPage), findsNothing);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, password);
        expect(field.obscureText, isTrue);
        await tester.enterText(find.byType(TextField), '${password}new');
        await tester.tap(find.text('开始查询'));
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<PhysicalTestPage>(find.byType(PhysicalTestPage))
                .password,
            '${password}new');
      } else {
        expect(find.byType(PhysicalTestPage), findsNothing);
        expect(find.text('开始查询'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (label, verified, role, visible) in [
    ('未配置账号可从试卷库进入配置引导', false, 'user', true),
    ('完成教务认证后显示试卷库入口', true, 'user', true),
    ('管理员未认证也显示试卷库入口', false, 'admin', true),
  ]) {
    testWidgets(label, (tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(loadOnStart: false),
            ),
            ChangeNotifierProvider<AuthProvider>(
              create: (_) => _Auth(User(
                id: 1,
                studentId: '20260001',
                nickname: '测试',
                role: role,
                academicConfigured: verified,
                createdAt: DateTime(2026),
              )),
            ),
          ],
          child: const MaterialApp(home: ToolboxScreen()),
        ),
      );

      expect(find.text('试卷库'), visible ? findsOneWidget : findsNothing);
    });
  }
}
