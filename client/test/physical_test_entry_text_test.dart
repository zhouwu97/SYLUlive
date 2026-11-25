import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/campus_data/storage/physical_cache_store.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/physical_test_screen.dart';
import 'package:shenliyuan/services/physical_credential_store.dart';

import 'helpers/golden_test_app.dart';
import 'helpers/load_test_fonts.dart';
import 'helpers/golden_viewport.dart';

class _Auth extends AuthProvider {
  _Auth() : super(Dio(), loadStoredAuth: false);
  int epoch = 0;
  @override
  bool get isLoggedIn => true;
  @override
  int get accountSessionEpoch => epoch;
  @override
  User get user => User(
      id: 77, studentId: 'fixture', nickname: '测试', createdAt: DateTime(2026));
  void relogin() {
    epoch++;
    notifyListeners();
  }
}

class _Credentials extends PhysicalCredentialStore {
  String? saved = '@Fixture0+&=%•';
  int writes = 0;
  int deletes = 0;
  bool failWrite = false;
  @override
  Future<void> write(String username, String password) async {
    writes++;
    if (failWrite) throw StateError('storage unavailable');
    saved = password;
  }

  @override
  Future<void> delete(String username) async {
    deletes++;
    saved = null;
  }
}

class _Cache extends PhysicalCacheStore {
  _Cache() : super(appUserId: '77', sourceAccountId: 'fixture');
  @override
  Future<void> discardUnownedLegacy(Iterable<String> years) async {}
  @override
  Future<Map<String, dynamic>?> readYear(String year) async => null;
  @override
  Future<void> writeYear(String year, Map<String, dynamic> data) async {}
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['PHYSICAL_QA_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('体测 $profile 网络失败保留密码，重试清掉旧错误并展示空成绩', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final auth = _Auth();
      final store = _Credentials();
      final dio = Dio();
      var logins = 0;
      final retry = Completer<void>();
      dio.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) async {
        if (options.path.endsWith('/check')) {
          logins++;
          if (logins == 1) {
            handler.reject(DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout));
            return;
          }
          await retry.future;
        }
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: options.path.endsWith('/check')
                ? {
                    'status': 'PASS',
                    'user_id': 'fixture-user',
                    'token': 'fixture-token'
                  }
                : {
                    'data': {
                      'total_grade': '',
                      'total_score': 0,
                      'data_arr': []
                    }
                  }));
      }));
      final key = GlobalKey();
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider(
                create: (_) => ThemeProvider(loadOnStart: false)),
          ],
          child: RepaintBoundary(
              key: key,
              child: GoldenTestApp(
                  themeMode:
                      profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
                  textScaler: profile == 'large-text'
                      ? const TextScaler.linear(1.3)
                      : TextScaler.noScaling,
                  home: PhysicalTestPage(
                      appUserId: '77',
                      username: 'fixture',
                      password: store.saved!,
                      dio: dio,
                      credentialStore: store,
                      cacheStore: _Cache())))));
      await tester.pumpAndSettle();
      expect(find.textContaining('连接失败或响应超时'), findsOneWidget);
      expect(store.deletes, 0);
      await _capture(tester, key, '$profile-error');
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(find.text('正在登录…'), findsOneWidget);
      expect(find.textContaining('连接失败或响应超时'), findsNothing);
      await _capture(tester, key, '$profile-loading');
      retry.complete();
      await tester.pumpAndSettle();
      expect(logins, 2);
      expect(store.writes, 1);
      expect(find.text('暂无成绩数据'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await _capture(tester, key, '$profile-empty');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      dio.close();
      auth.dispose();
    });
  }

  for (final changedSession in [false, true]) {
    testWidgets('保存失败不误报登录失败，旧会话不保存密码：切换=$changedSession', (tester) async {
      final auth = _Auth();
      final store = _Credentials()..failWrite = true;
      final gate = Completer<void>();
      final dio = Dio();
      dio.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) async {
        await gate.future;
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: options.path.endsWith('/check')
                ? {
                    'status': 'PASS',
                    'user_id': 'fixture-user',
                    'token': 'fixture-token'
                  }
                : {
                    'data': {'data_arr': []}
                  }));
      }));
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider(
                create: (_) => ThemeProvider(loadOnStart: false)),
          ],
          child: GoldenTestApp(
              home: PhysicalTestPage(
                  appUserId: '77',
                  username: 'fixture',
                  password: store.saved!,
                  dio: dio,
                  credentialStore: store,
                  cacheStore: _Cache()))));
      await tester.pump();
      if (changedSession) {
        auth.relogin();
        await tester.pump();
      }
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.deletes, 0);
      expect(store.writes, changedSession ? 0 : 1);
      expect(find.textContaining('登录失败'), findsNothing);
      expect(find.text(changedSession ? '账号已切换，请返回重新打开体测' : '暂无成绩数据'),
          findsOneWidget);
      if (!changedSession) {
        expect(find.textContaining('密码未能安全保存'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
      dio.close();
      auth.dispose();
    });
  }

  test('体测页报告入口文案为查看超越了多少大学生', () {
    final source =
        File('lib/screens/physical_test_screen.dart').readAsStringSync();
    expect(source, contains('查看超越了多少大学生'));
    expect(source, isNot(contains('查看超越报告')));
  });
}
