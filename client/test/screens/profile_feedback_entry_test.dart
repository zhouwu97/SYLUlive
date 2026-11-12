import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/feedback/feedback_center_screen.dart';
import 'package:shenliyuan/screens/feedback/feedback_create_screen.dart';
import 'package:shenliyuan/screens/profile_screen.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/utils/app_navigator.dart';

import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.dio, {this.loggedIn = true});

  @override
  final Dio dio;

  final bool loggedIn;

  @override
  User? get user => loggedIn
      ? User(
          id: 20,
          studentId: 'test',
          nickname: '本地测试',
          createdAt: DateTime(2026))
      : null;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  bool get hasRecoverableSession => false;

  @override
  int get accountSessionEpoch => 1;

  @override
  Future<void> refreshUser() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Completer<ResponseBody>? submission;
  bool failTickets = false;

  ResponseBody response(Object data, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(data), status, headers: {
        Headers.contentTypeHeader: ['application/json']
      });

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.path == '/feedback/tickets') {
      if (options.method == 'POST') {
        final pending = submission;
        if (pending != null) return pending.future;
        return response({'message': 'ok'}, 201);
      }
      return failTickets
          ? response({'error': '暂时无法读取'}, 503)
          : response({'tickets': [], 'total': 0});
    }
    if (options.path == '/user/invitations') return response([]);
    if (options.path == '/user/course-evaluations') {
      return response({
        'items': [],
        'content_counts': {'posts': 0, 'market': 0, 'evaluations': 0},
      });
    }
    if (options.path == '/user/canteen-reviews') {
      return response({'items': [], 'has_more': false});
    }
    return response({'count': 0, 'unread_count': 3});
  }

  @override
  void close({bool force = false}) {}
}

final _captureKey = GlobalKey();

Future<void> _pump(WidgetTester tester, _Api api,
    {bool loggedIn = true, bool dark = false, double scale = 1}) async {
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'))
    ..httpClientAdapter = api;
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
          create: (_) => _Auth(dio, loggedIn: loggedIn)),
      ChangeNotifierProvider(create: (_) => ThemeProvider(loadOnStart: false)),
      ChangeNotifierProvider(create: (_) => EduProvider(dio)),
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(
          create: (_) => MessageProvider(dio, enableRealtime: false)),
    ],
    child: RepaintBoundary(
      key: _captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        routes: {
          '/login': (_) => Scaffold(appBar: AppBar(title: const Text('登录测试页'))),
        },
        home: Builder(
          builder: (context) => ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const ProfileScreen(),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('创建工单'), 200,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['FEEDBACK_QA_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary = _captureKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    currentHomeTabIndex.value = 4;
    PackageInfo.setMockInitialValues(
      appName: '沈理校园',
      packageName: 'test.sylulive',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('工单入口及创建页适配主题与大字号 dark=$dark scale=$scale', (tester) async {
        await _pump(tester, _Api(), dark: dark, scale: scale);
        await tester.ensureVisible(find.text('我的工单'));
        await tester.pumpAndSettle();
        expect(find.text('反馈 Bug 或提交功能建议'), findsOneWidget);
        expect(find.text('查看处理进度与管理员回复'), findsOneWidget);
        await _capture(tester, 'profile-$dark-$scale');
        await tester.tap(find.text('创建工单'));
        await tester.pumpAndSettle();
        expect(find.byType(FeedbackCreateScreen), findsOneWidget);
        expect(find.text('例如：课表重新同步后课程时间没有更新'), findsOneWidget);
        await _capture(tester, 'create-$dark-$scale');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final entry in ['创建工单', '我的工单']) {
    testWidgets('未登录点击$entry先进入登录页且不请求工单接口', (tester) async {
      final api = _Api();
      await _pump(tester, api, loggedIn: false);
      await tester.ensureVisible(find.text(entry));
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
      expect(find.text('登录测试页'), findsOneWidget);
      expect(find.byType(FeedbackCreateScreen), findsNothing);
      expect(find.byType(FeedbackCenterScreen), findsNothing);
      expect(
          api.requests.where((o) => o.path.startsWith('/feedback/')), isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('创建 Bug 工单失败保留内容，重试成功后可查看我的工单', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.tap(find.text('创建工单'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '课表无法刷新');
    await tester.enterText(find.byType(TextField).at(1), '点击同步后课表没有更新');
    tester.testTextInput.hide();
    await tester.ensureVisible(find.text('提交反馈'));
    await tester.pumpAndSettle();
    api.submission = Completer<ResponseBody>();
    await tester.tap(find.text('提交反馈'));
    await tester.pump();
    expect(
        tester
            .widget<ElevatedButton>(find.byType(ElevatedButton).last)
            .onPressed,
        isNull);
    api.submission!.complete(api.response({'error': '暂时不可用'}, 503));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackCreateScreen), findsOneWidget);
    expect(find.text('课表无法刷新'), findsOneWidget);
    expect(find.text('点击同步后课表没有更新'), findsOneWidget);
    await _capture(tester, 'submit-error');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    api.submission = null;
    await tester.tap(find.text('提交反馈'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackCreateScreen), findsNothing);
    final submissions = api.requests.where((o) => o.method == 'POST').toList();
    expect(submissions, hasLength(2));
    expect(submissions.last.data['type'], 'bug');
    expect(submissions.last.data['title'], '课表无法刷新');
    expect(submissions.last.data['current_route'], '我的 / 创建工单');
    expect(submissions.last.headers['Idempotency-Key'],
        submissions.first.headers['Idempotency-Key']);
    await tester.ensureVisible(find.text('我的工单'));
    api.failTickets = true;
    await tester.tap(find.text('我的工单'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackCenterScreen), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await _capture(tester, 'tickets-error');
    api.failTickets = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无反馈记录'), findsOneWidget);
    await _capture(tester, 'tickets-empty');
    await tester.tap(find.text('创建工单'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackCreateScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
