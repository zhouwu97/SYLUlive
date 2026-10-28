import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/admin_candidates_screen.dart';
import 'package:shenliyuan/screens/admin_members_screen.dart';
import 'package:shenliyuan/screens/super_admin_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _AcademicAdminAdapter implements HttpClientAdapter {
  _AcademicAdminAdapter(this.respond);

  final FutureOr<Object?> Function(RequestOptions) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = await respond(options);
    return ResponseBody.fromString(
      jsonEncode(body ?? {'error': '测试失败响应'}),
      body == null ? 503 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      },
    );
  }
}

const _configuredUser = {
  'id': 901,
  'nickname': '已登记教务用户',
  'student_id': 'configured-901',
  'academic_configured': true,
  'student_verified': false,
  'edu_bound': false,
  'role': 'admin',
};

const _stats = {'total': 7, 'edu': 4, 'other': 3, 'eligible': 1};

Object _candidates(List<Object> users) => {
      'items': users,
      'total': users.length,
      'page': 1,
      'page_size': 20,
      'has_more': false,
    };

Widget _app(
  Widget screen,
  FutureOr<Object?> Function(RequestOptions) respond, {
  ThemeMode theme = ThemeMode.light,
  TextScaler scaler = TextScaler.noScaling,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = _AcademicAdminAdapter(respond);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(dio, loadStoredAuth: false),
      ),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
    ],
    child: GoldenTestApp(
      home: RepaintBoundary(key: const Key('admin-qa'), child: screen),
      themeMode: theme,
      textScaler: scaler,
    ),
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('ADMIN_ACADEMIC_QA_DIR');
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('admin-qa')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(directory).createSync(recursive: true);
    File('$directory/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    testWidgets('候选人教务登记与身份分开展示 ${dark ? '深色大字号' : '浅色'}', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pumpWidget(
        _app(
          const AdminCandidatesScreen(),
          (options) => options.path.endsWith('/stats')
              ? _stats
              : _candidates([_configuredUser]),
          theme: dark ? ThemeMode.dark : ThemeMode.light,
          scaler: dark ? GoldenTextProfile.large.scaler : TextScaler.noScaling,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('教务有记录'), findsOneWidget);
      expect(find.text('暂无记录'), findsOneWidget);
      expect(find.text('学号/账号：configured-901'), findsOneWidget);
      expect(find.text('教务配置：已登记\n学生身份：未验证'), findsOneWidget);
      expect(find.text('其他'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(
          tester, dark ? 'candidates-dark-large' : 'candidates-light');
    });
  }

  testWidgets('成员页和超级管理员页使用相同的登记与身份状态', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    for (final screen in [
      const AdminMembersScreen(),
      const SuperAdminScreen()
    ]) {
      await tester.pumpWidget(
        _app(screen, (options) {
          if (options.path == '/admin/members' ||
              options.path == '/super/users') {
            return [_configuredUser];
          }
          return <Object>[];
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('学号/账号：configured-901'), findsOneWidget);
      expect(find.text('教务配置：已登记\n学生身份：未验证'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
          tester, screen is AdminMembersScreen ? 'members' : 'super-users');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('候选人加载失败后可重试并恢复登记统计', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    var fail = true;
    await tester.pumpWidget(
      _app(const AdminCandidatesScreen(), (options) {
        if (fail) return null;
        return options.path.endsWith('/stats')
            ? _stats
            : _candidates([_configuredUser]);
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('候选人加载失败'), findsOneWidget);
    expect(find.text('统计暂不可用'), findsOneWidget);
    await _capture(tester, 'candidates-error');

    fail = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('学号/账号：configured-901'), findsOneWidget);
    expect(find.text('统计暂不可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('候选人从加载过渡到空态且关闭页面后的旧响应不报错', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final pending = Completer<Object?>();
    await tester.pumpWidget(
      _app(
        const AdminCandidatesScreen(),
        (options) => options.path.endsWith('/stats') ? _stats : pending.future,
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    pending.complete(_candidates([]));
    await tester.pumpAndSettle();
    expect(find.text('暂无候选人'), findsOneWidget);
    await _capture(tester, 'candidates-empty');

    final lateResponse = Completer<Object?>();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _app(const AdminCandidatesScreen(), (_) => lateResponse.future),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    lateResponse.complete(_candidates([_configuredUser]));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
