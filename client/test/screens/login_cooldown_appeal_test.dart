import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/config/app_contacts.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/login_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';

const _account = 'blocked@example.invalid';
const _password = 'synthetic-password42';
AuthResult _limited() => AuthResult.failure(
      '连续登录失败次数过多，请在1天后重试，或向开发者申诉',
      statusCode: 429,
      errorCode: 'LOGIN_COOLDOWN',
      retryAfterSeconds: 86400,
    );

class _Auth extends AuthProvider {
  _Auth() : super(Dio(), loadStoredAuth: false);
  Completer<AuthResult>? pending;
  AuthResult result = _limited();
  int calls = 0;
  String? submitted;
  @override
  Future<AuthResult> login(String account, String password) async {
    calls++;
    submitted = account;
    if (pending != null) return pending!.future;
    return result;
  }
}

Future<GlobalKey> _pump(WidgetTester tester, _Auth auth,
    {ThemeMode mode = ThemeMode.light, double scale = 1}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final capture = GlobalKey();
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider(create: (_) => ThemeProvider(loadOnStart: false)),
    ],
    child: RepaintBoundary(
      key: capture,
      child: GoldenTestApp(
        themeMode: mode,
        textScaler: TextScaler.linear(scale),
        home: const LoginScreen(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, _account);
  await tester.enterText(find.byType(TextField).at(1), _password);
  await tester.ensureVisible(find.text('登录').last);
  await tester.tap(find.text('登录').last);
  await tester.pump();
  return capture;
}

Future<void> _save(WidgetTester tester, GlobalKey capture, String name) async {
  final dir = Platform.environment['SECURITY_QA_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in ['light', 'dark', 'large']) {
    testWidgets('未登录可查看一天冷却并复制开发者申诉信息 $profile', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final auth = _Auth();
      final capture = await _pump(tester, auth,
          mode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
          scale: profile == 'large' ? 1.3 : 1);
      await tester.pumpAndSettle();
      expect(find.text('登录受限'), findsOneWidget);
      expect(find.textContaining('1天后'), findsOneWidget);
      expect(
          DefaultTextStyle.of(tester.element(find.text('知道了')))
              .style
              .fontFamily,
          'NotoSansCJKsc');
      expect(auth.isLoggedIn, isFalse);
      expect(auth.calls, 1);
      await _save(tester, capture, 'login-$profile-cooldown');
      await tester.tap(find.text('向开发者申诉'));
      await tester.pumpAndSettle();
      final template =
          tester.widget<SelectableText>(find.byType(SelectableText));
      expect(template.data, contains(_account));
      expect(template.data, contains(AppContacts.legalContactText));
      expect(template.data, isNot(contains(_password)));
      await _save(tester, capture, 'login-$profile-appeal');
      await tester.tap(find.text('复制申诉信息'));
      await tester.pumpAndSettle();
      expect(copied, template.data);
      expect(find.text('申诉信息已复制，请联系开发者人工核查'), findsOneWidget);
      expect(auth.calls, 1, reason: '查看和复制联系人不发送申诉或重试登录');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('迟到的限制响应使用提交账号，复制失败仍可手动选择', (tester) async {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        throw PlatformException(code: 'clipboard-unavailable');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final auth = _Auth()..pending = Completer<AuthResult>();
    await _pump(tester, auth);
    expect(auth.submitted, _account);
    await tester.enterText(
        find.byType(TextField).first, 'edited@example.invalid');
    auth.pending!.complete(_limited());
    await tester.pumpAndSettle();
    await tester.tap(find.text('向开发者申诉'));
    await tester.pumpAndSettle();
    final template = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(
        DefaultTextStyle.of(tester.element(find.text('关闭'))).style.fontFamily,
        'NotoSansCJKsc');
    expect(template.data, contains(_account));
    expect(template.data, isNot(contains('edited@example.invalid')));
    await tester.tap(find.text('复制申诉信息'));
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请长按文字手动复制'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通密码错误不显示冷却或申诉弹窗且可以重试', (tester) async {
    final auth = _Auth()
      ..result = AuthResult.failure('账号或密码错误', statusCode: 401);
    await _pump(tester, auth);
    await tester.pumpAndSettle();
    expect(find.text('账号或密码错误'), findsOneWidget);
    expect(find.text('登录受限'), findsNothing);
    expect(find.text('向开发者申诉'), findsNothing);
    await tester.tap(find.text('登录').last);
    await tester.pumpAndSettle();
    expect(auth.calls, 2);
  });
}
