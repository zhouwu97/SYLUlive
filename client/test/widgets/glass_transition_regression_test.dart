import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart' show getSharedDio;
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/court_hub_screen.dart';
import 'package:shenliyuan/widgets/app_bottom_sheet.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'package:shenliyuan/widgets/app_popup_menu.dart';
import 'package:shenliyuan/widgets/app_surface_transition.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_renderer.dart';

import '../helpers/active_backdrop_filters.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';

Future<void> _frame(WidgetTester tester, GlobalKey capture, String name,
    {Offset? inside, Offset? outside, int surfaceRed = 255}) async {
  await tester.runAsync(() async {
    final image = await (capture.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage();
    try {
      final bytes = (await image.toByteData())!;
      int red(Offset p) =>
          bytes.getUint8((p.dy.round() * image.width + p.dx.round()) * 4);
      final directory = Platform.environment['BACKGROUND_QA_DIR'];
      if (directory != null) {
        await Directory(directory).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$directory/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
      }
      if (inside != null && outside != null) {
        final floor = red(outside) < surfaceRed ? red(outside) : surfaceRed;
        expect(red(inside), greaterThanOrEqualTo(floor - 2),
            reason: '$name: 表面合成不能比背景和目标底色同时更暗');
      }
    } finally {
      image.dispose();
    }
  });
}

void _expectNoFilterUnderFade() {
  for (final filter in activeBackdropFilters().evaluate()) {
    filter.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is FadeTransition) {
        expect(widget.opacity.value, anyOf(0, 1), reason: '背景滤镜不能放进半透明的整层淡入');
      }
      if (widget is Opacity) {
        expect(widget.opacity, anyOf(0, 1));
      }
      return true;
    });
  }
}

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  testWidgets('液态底栏降级模糊使用同一转场保护且独立于毛玻璃开关', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setFrostedGlass(false);
    final animation = AnimationController(vsync: tester, value: 1);
    addTearDown(animation.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
          home: Scaffold(
              body: Center(
                  child: SizedBox(
        width: 360,
        height: 80,
        child: FadeTransition(
          opacity: animation,
          child: const LiquidGlassRenderer(
            lens: Rect.fromLTWH(12, 12, 72, 50),
            press: 0,
            pointer: Offset.zero,
            labels: ['首页'],
            icons: [Icons.home],
            badges: {},
            accent: Colors.teal,
            enabled: false,
          ),
        ),
      )))),
    ));
    await tester.pumpAndSettle();
    for (final progress in [.1, .5, .9, 1.0, .5, 1.0]) {
      animation.value = progress;
      await tester.pump();
      expect(activeBackdropFilters(),
          progress == 1 ? findsOneWidget : findsNothing);
    }
    await theme.setFrostedGlass(true);
    await tester.pump();
    expect(activeBackdropFilters(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生页面淡入在缓存子树中暂停背景采样并在结束恢复', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    final animation = AnimationController(vsync: tester, value: 1);
    addTearDown(animation.dispose);
    final field = TextEditingController(text: '原生页面草稿');
    addTearDown(field.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
        home: Scaffold(
          body: FadeTransition(
            opacity: animation,
            child: RepaintBoundary(
              child: AppCardSurface(child: TextField(controller: field)),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(EditableText));
    for (final progress in [0.0, .1, .5, .9, 1.0, .9, .1, 0.0, 1.0]) {
      animation.value = progress;
      await tester.pump();
      expect(
          activeBackdropFilters(), progress == 1 ? findsWidgets : findsNothing);
      expect(tester.state(find.byType(EditableText)), same(state));
      expect(field.text, '原生页面草稿');
    }
    expect(tester.takeException(), isNull);
  });

  for (final glass in [false, true]) {
    testWidgets('弹窗保留嵌套导航、遮罩、取消限制与返回值 glass=$glass', (tester) async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlass(glass);
      final inner = GlobalKey<NavigatorState>();
      final observer = _RouteObserver();
      String? result;
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
          home: Navigator(
            key: inner,
            observers: [observer],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('打开'),
                  onPressed: () async {
                    result = await showAppDialog<String>(
                      context: context,
                      useRootNavigator: false,
                      barrierDismissible: false,
                      barrierColor: Colors.black26,
                      barrierLabel: '案件结果',
                      requestFocus: false,
                      routeSettings: const RouteSettings(name: '/result'),
                      builder: (context) => AppAlertDialog(
                        title: const Text('确认'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, 'kept'),
                            child: const Text('返回'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final route = observer.latest! as DialogRoute<dynamic>;
      expect(route.settings.name, '/result');
      expect(route.navigator, inner.currentState);
      expect(route.barrierColor, Colors.black26);
      expect(route.barrierLabel, '案件结果');
      expect(route.requestFocus, isFalse);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('确认'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(result, 'kept');
      expect(find.text('确认'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('结案公示真实入口的弹窗中间帧没有整层淡入黑块', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone390x844);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setComponentOpacity(.25);
    await theme.setFrostedGlass(true);
    final interceptor = InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: [
        if (options.path == '/appeals/public')
          {
            'id': 1,
            'status': 'reject',
            'result': '维持原处理',
            'resolution_source': 'manual_review',
            'escalation_reason': 'insufficient_jury',
          }
      ]));
    });
    getSharedDio().interceptors.insert(0, interceptor);
    addTearDown(() => getSharedDio().interceptors.remove(interceptor));
    final capture = GlobalKey();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: RepaintBoundary(
        key: capture,
        child: const GoldenTestApp(home: CourtHubScreen(initialTab: 3)),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('案件 #1 · 维持处理'));
    await tester.pump();
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await _frame(tester, capture, 'court-forward-$frame');
      _expectNoFilterUnderFade();
      expect(
          find.descendant(
              of: find.byType(AppDialog), matching: activeBackdropFilters()),
          findsWidgets,
          reason: '应用弹窗应持续平滑模糊，不能依赖原生淡入的暂停采样兜底');
    }
    await tester.pumpAndSettle();
    expect(find.text('案件 #1 · 已结案'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pump();
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await _frame(tester, capture, 'court-reverse-$frame');
      _expectNoFilterUnderFade();
    }
    await tester.pumpAndSettle();
    expect(find.byType(AppAlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final profile in ['light', 'dark', 'large', 'opaque', 'off', 'clean']) {
    for (final kind in ['container', 'material', 'card']) {
      testWidgets('$profile $kind 表面及嵌套卡片过渡保留输入、焦点和尺寸', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        if (profile != 'clean') {
          await theme.setBackgroundImage('morenbeijing.jpeg');
        }
        await theme.setComponentOpacity(profile == 'opaque' ? 1 : .25);
        await theme.setFrostedGlass(profile != 'off');
        final animation = AnimationController(vsync: tester, value: 1);
        addTearDown(animation.dispose);
        final input = TextEditingController(text: '保留草稿');
        final focus = FocusNode();
        addTearDown(input.dispose);
        addTearDown(focus.dispose);
        final capture = GlobalKey();
        const boundsKey = ValueKey('surface-bounds');
        final content = Center(
          child: AppCardSurface(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            width: 180,
            child: TextField(controller: input, focusNode: focus),
          ),
        );
        final color =
            profile == 'dark' ? const Color(0xFF212121) : Colors.white;
        final surface = switch (kind) {
          'container' => AppCardSurface(color: color, child: content),
          'material' => AppCardMaterial(color: color, child: content),
          _ => AppCard(color: color, margin: EdgeInsets.zero, child: content),
        };
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(profile == 'large' ? 1.3 : 1),
              home: Scaffold(
                backgroundColor: const Color(0xFFB0B0B0),
                body: Center(
                  child: AppSurfaceFadeTransition(
                    opacity: animation,
                    child: SizedBox(
                      key: boundsKey,
                      width: 280,
                      height: 200,
                      child: surface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextField));
        await tester.enterText(find.byType(TextField), '输入过程中切换');
        final editable = tester.state(find.byType(EditableText));
        final bounds = tester.getRect(find.byKey(boundsKey));
        for (final progress in [
          0.0,
          .1,
          .25,
          .5,
          .75,
          1.0,
          .75,
          .25,
          0.0,
          1.0
        ]) {
          animation.value = progress;
          await tester.pump();
          _expectNoFilterUnderFade();
          expect(tester.getRect(find.byKey(boundsKey)), bounds);
          expect(tester.state(find.byType(EditableText)), same(editable));
          expect(input.text, '输入过程中切换');
          expect(focus.hasFocus, isTrue);
          if (progress == .1 || progress == .5 || progress == 1) {
            await _frame(tester, capture, '$profile-$kind-$progress',
                inside: bounds.topLeft + const Offset(16, 16),
                outside: Offset(12, bounds.top + 16),
                surfaceRed: profile == 'dark' ? 33 : 255);
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final kind in ['menu', 'sheet']) {
    testWidgets('$kind 进入退出中间帧没有毛玻璃黑块', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setComponentOpacity(.25);
      await theme.setFrostedGlass(true);
      final capture = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              backgroundColor: const Color(0xFFB0B0B0),
              body: Center(child: Builder(builder: (context) {
                if (kind == 'menu') {
                  return AppPopupMenuButton<int>(
                    tooltip: '打开',
                    color: Colors.white,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 1, child: Text('选择')),
                      PopupMenuItem(value: 2, child: Text('第二项')),
                    ],
                  );
                }
                return TextButton(
                  onPressed: () => showAppModalBottomSheet<void>(
                    context: context,
                    backgroundColor: Colors.white,
                    builder: (_) => const SizedBox(height: 240),
                  ),
                  child: const Text('打开'),
                );
              })),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(kind == 'menu' ? find.byTooltip('打开') : find.text('打开'));
      await tester.pump();
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final rect = kind == 'menu'
            ? tester.getRect(find.byType(AppCardMaterial).last)
            : tester.getRect(find.byType(BottomSheet));
        await _frame(tester, capture, '$kind-forward-$frame',
            inside: Offset(rect.right - 12, rect.top + 12),
            outside: Offset(12, rect.top + 12));
        _expectNoFilterUnderFade();
      }
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await _frame(tester, capture, '$kind-reverse-$frame');
        _expectNoFilterUnderFade();
      }
      await tester.pumpAndSettle();
      expect(activeBackdropFilters(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
