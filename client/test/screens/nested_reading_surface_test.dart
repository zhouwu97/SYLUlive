import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/blog_screen.dart';
import 'package:shenliyuan/screens/chat_list_screen.dart';
import 'package:shenliyuan/screens/login_screen.dart';
import 'package:shenliyuan/screens/privacy_center_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

class _ReadOnlyAuth extends AuthProvider {
  _ReadOnlyAuth() : super(Dio(), loadStoredAuth: false);
  @override
  bool get isLoggedIn => true;
  @override
  User get user => User(
      id: 1, studentId: 'fixture', nickname: '验收', createdAt: DateTime(2026));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('私信页面退出时关闭轮询，不在销毁期间通知界面重建', (tester) async {
    final visible = ValueNotifier(true);
    final messages = MessageProvider(Dio(), enableRealtime: false);
    final appearance = ThemeProvider(loadOnStart: false);
    final auth = _ReadOnlyAuth();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider.value(value: messages),
        ChangeNotifierProvider.value(value: appearance),
      ],
      child: GoldenTestApp(
          home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, show, __) =>
            show ? const ChatListScreen() : const SizedBox.shrink(),
      )),
    ));
    await tester.pumpAndSettle();
    expect(messages.fallbackPollingActive, isTrue);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(messages.fallbackPollingActive, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    visible.dispose();
    messages.dispose();
    auth.dispose();
    appearance.dispose();
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('博客阅读器保留背景、输入和材质切换 dark=$dark scale=$scale', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(.75);
        await appearance.setFrostedGlass(true);
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(scale),
            home: const BlogScreen(),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Flutter 状态管理深度对比').first);
        await tester.pumpAndSettle();
        expect(find.byType(CustomBackgroundLayer), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.byType(TextField), 600,
            scrollable: find.byType(Scrollable).first);
        await tester.enterText(find.byType(TextField), '保留阅读草稿');
        final rect = tester.getRect(find.byType(TextField));
        for (final glass in [false, true]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          final field = tester.widget<TextField>(find.byType(TextField));
          expect(field.controller!.text, '保留阅读草稿');
          expect(tester.getRect(find.byType(TextField)), rect);
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('登录及密码重置按钮在浅色强调底上可读 dark=$dark', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final appearance = ThemeProvider(loadOnStart: false);
      addTearDown(appearance.dispose);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: appearance),
          ChangeNotifierProvider<AuthProvider>(
              create: (_) => AuthProvider(Dio(), loadStoredAuth: false)),
        ],
        child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            home: const LoginScreen()),
      ));
      await tester.pumpAndSettle();
      void checkButton(String text) {
        final button = tester.widget<FilledButton>(find.ancestor(
            of: find.text(text), matching: find.byType(FilledButton)));
        final foreground = button.style!.foregroundColor!.resolve({})!;
        final background = button.style!.backgroundColor!.resolve({})!;
        expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
      }

      checkButton('登录');
      await tester.tap(find.text('忘记密码？'));
      await tester.pumpAndSettle();
      checkButton('确认重置');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('查阅个人信息的子路由拥有壁纸且保留只读资料', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('shenliyuan/keep_alive'), (_) async => true);
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('shenliyuan/keep_alive'), null));
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        h.resolve(Response(
            requestOptions: o,
            statusCode: 200,
            data: o.path.endsWith('/data')
                ? {
                    'account': {'nickname': '本地只读验收'},
                    'legal_consents': []
                  }
                : {'items': []}));
      }));
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    await appearance.setBackgroundImage('morenbeijing.jpeg');
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appearance),
        ChangeNotifierProvider<AuthProvider>(
            create: (_) => AuthProvider(dio, loadStoredAuth: false)),
      ],
      child: const GoldenTestApp(home: PrivacyCenterScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查阅个人信息'));
    await tester.pumpAndSettle();
    expect(find.text('本地只读验收'), findsOneWidget);
    expect(find.byType(CustomBackgroundLayer), findsOneWidget);
    expect(find.byType(AppCardSurface), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
