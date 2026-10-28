import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/bottom_nav.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_renderer.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_runtime.dart';
import 'package:shenliyuan/widgets/liquid_glass/liquid_glass_qa_screen.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  testWidgets('关闭档不创建液态渲染器，普通悬浮入口仍切页', (tester) async {
    final h = await pumpNav(tester);
    await h.theme.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    await tester.pumpAndSettle();
    expect(find.byType(LiquidGlassRenderer), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-3')));
    await tester.pumpAndSettle();
    expect(h.selected.value, 3);
    expect(h.taps, 1);
    expect(h.commits, 0);
    await h.theme.loadThemeForTesting();
    expect(h.theme.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
  });
  testWidgets('正式底栏实时应用持久化的清透材质', (tester) async {
    final h = await pumpNav(tester);
    await h.theme.setBottomNavClearMaterial(true);
    await tester.pumpAndSettle();
    final optics = tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer));
    expect(optics.blur, 0);
    expect(optics.tint, .06);
    expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);
    await h.theme.loadThemeForTesting();
    expect(h.theme.bottomNavClearMaterial, isTrue);
  });
  testWidgets('透镜从原处进入按压态并连续移向课表，跟手且松手才切页', (tester) async {
    final h = await pumpNav(tester);
    final target = tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-2')));
    final drag = await tester.startGesture(target);
    expect(h.position.value, 0, reason: '按下不得瞬移');
    await tester.pump(const Duration(milliseconds: 16));
    expect(h.position.value, greaterThan(0));
    expect(h.position.value, lessThan(1));
    expect(tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer)).press, greaterThan(0));
    await drag.moveBy(const Offset(1, 0));
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(h.position.value, greaterThan(.5));
    expect(h.position.value, lessThan(2), reason: '液态按压途中应仍在行进');
    expect(h.selected.value, 0);
    expect(h.commits, 0);
    expect(tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer)).press, greaterThan(.4));
    await tester.pumpAndSettle();
    expect(h.position.value, closeTo(2, .03));
    expect(h.commits, 0);
    final next = tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-3')));
    for (var i = 1; i <= 12; i++) {
      await drag.moveTo(Offset.lerp(target, next, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(h.position.value, greaterThan(2.4));
    expect(h.selected.value, 0);
    await drag.up();
    await tester.pumpAndSettle();
    expect(h.selected.value, 3);
    expect(h.commits, 1);
    expect(tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer)).press, closeTo(0, .001));
  });

  testWidgets('QA 清透开关在按压态仍区分磨砂和清透像素', (tester) async {
    await tester.runAsync(() async { await loadLiquidGlassProgram(); });
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: RepaintBoundary(
      key: boundaryKey, child: const LiquidGlassQaScreen())));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    Future<List<int>> capture() async {
      return (await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final data = bytes.buffer.asUint8List().toList();
        final start = ((image.height - 100) * image.width * 4).clamp(0, data.length);
        image.dispose();
        return data.sublist(start);
      }))!;
    }
    final held = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-2'))), pointer: 7);
    await tester.pumpAndSettle();
    expect(tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer)).press, greaterThan(.9));
    final frosted = await capture();
    await tester.tap(find.text('清透材质'));
    await tester.pumpAndSettle();
    final clear = await capture();
    expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);
    var changed = 0;
    for (var i = 0; i < clear.length; i += 4) {
      if ((clear[i] - frosted[i]).abs() > 10) changed++;
    }
    expect(changed, greaterThan(1000), reason: '不能只切换按钮，真实底栏材质必须有明显像素差异');
    await held.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('同一拖动高性能形变更轻，高画质与高性能都保持折射', (tester) async {
    final bends = <double>[];
    final stretches = <double>[];
    for (final mode in [
      BottomNavPerformanceMode.highQuality,
      BottomNavPerformanceMode.highPerformance
    ]) {
      final h = await pumpNav(tester);
      await h.theme.setBottomNavPerformanceMode(mode);
      await tester.pumpAndSettle();
      final start =
          tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-0')));
      final drag = await tester.startGesture(start);
      for (var i = 1; i <= 12; i++) {
        await drag.moveTo(start + Offset(i * 13, -12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final optics =
          tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer));
      bends.add(optics.bend.distance);
      stretches.add(optics.stretch);
      expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);
      await drag.cancel();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(bends.first, greaterThan(2));
    expect(bends.last, closeTo(bends.first * .35, .001));
    expect(stretches.last, closeTo(stretches.first * .35, .001));
  });

  testWidgets('液态导航保留五个触控入口、语义、角标，松手只提交一次', (tester) async {
    final h = await pumpNav(tester);
    final semantics = tester.ensureSemantics();

    for (var i = 0; i < 5; i++) {
      expect(tester.getSize(find.byKey(ValueKey('bottom-nav-item-$i'))).height,
          greaterThanOrEqualTo(44));
    }
    expect(find.bySemanticsLabel('我，有新消息'), findsOneWidget);
    final start =
        tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-0')));
    final gesture = await tester.startGesture(start);
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      await gesture.moveTo(start + Offset(i * 13, -12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final optics =
        tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer));
    expect(optics.bend.dx, greaterThan(2));
    expect(optics.stretch, greaterThan(.07));
    expect(h.commits, 0);
    expect(h.selected.value, 0);
    await snapshot(tester, h, 'drag');
    await gesture.up();
    expect(h.commits, 1);
    await tester.pumpAndSettle();
    expect(h.selected.value, 2);
    expect(h.position.value, closeTo(2, .001));
    expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);
    expect(tester.binding.hasScheduledFrame, isFalse);
    semantics.dispose();
  });

  testWidgets('取消和第二指针不提交；快速重新抓取仍可导航', (tester) async {
    final h = await pumpNav(tester);
    final first = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-0'))),
        pointer: 1);
    final second = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-4'))),
        pointer: 2);
    await second.up();
    await first.moveBy(const Offset(170, 0));
    await tester.pump(const Duration(milliseconds: 40));
    await first.cancel();
    await tester.pumpAndSettle();
    expect(h.commits, 0);
    expect(h.selected.value, 0);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-4')));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-1')));
    await tester.pumpAndSettle();
    expect(h.selected.value, 1);
    expect(h.position.value, closeTo(1, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('父页面转场通知不会覆盖正在吸附的透镜；外部切页仍同步', (tester) async {
    final h = await pumpNav(tester);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-4')));
    for (var i = 0; i < 6; i++) {
      h.position.value = i / 6;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(h.position.value, closeTo(4, .001));
    h.selected.value = 2;
    h.position.value = 2;
    await tester.pumpAndSettle();
    expect(h.position.value, closeTo(2, .001));
  });

  testWidgets('Pad 限宽和连续缩放后首尾点击对齐', (tester) async {
    final h = await pumpNav(tester,
        viewport: GoldenViewports.tabletLandscape1280x800);
    final dock = find.byKey(const ValueKey('bottom-nav-floating-dock'));
    expect(tester.getSize(dock).width, 440);
    expect(tester.getCenter(dock).dx, 640);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-4')));
    await tester.pumpAndSettle();
    expect(h.selected.value, 4);
    await setGoldenViewport(tester, GoldenViewports.tabletSplit600x800);
    await tester.pumpAndSettle();
    expect(tester.getSize(dock).width, 440);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-0')));
    await tester.pumpAndSettle();
    expect(h.selected.value, 0);
  });

  testWidgets('浅色、深色、1.3 倍文字、滚动采样使用正式渲染器', (tester) async {
    for (final mode in ['light', 'dark', 'large-text']) {
      final h = await pumpNav(tester,
          dark: mode == 'dark', textScale: mode == 'large-text' ? 1.3 : 1);
      expect(liquidGlassRuntimeStatus.value.tier, LiquidGlassTier.a);
      await snapshot(tester, h, mode);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('高性能保留真实折射；仅缺少采样容器才降级且可点击', (tester) async {
    for (final scope in [true, false]) {
      final h = await pumpNav(tester, withScope: scope);
      if (scope) {
        await h.theme.setBottomNavPerformanceMode(
            BottomNavPerformanceMode.highPerformance);
        await tester.pumpAndSettle();
      }
      expect(liquidGlassRuntimeStatus.value.tier,
          scope ? LiquidGlassTier.a : LiquidGlassTier.c);
      await tester.tap(find.byKey(const ValueKey('bottom-nav-item-3')));
      await tester.pumpAndSettle();
      expect(h.selected.value, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('减少动态效果、无障碍动作保留即时导航', (tester) async {
    final h = await pumpNav(tester, reduced: true);
    final semantics = tester.ensureSemantics();

    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-4')));
    await tester.pumpAndSettle();
    final optics =
        tester.widget<LiquidGlassRenderer>(find.byType(LiquidGlassRenderer));
    expect(optics.press, 0);
    expect(optics.bend, Offset.zero);
    expect(h.selected.value, 4);
    final node = tester
        .getSemantics(find.byKey(const ValueKey('bottom-nav-semantic-1')));
    tester
        .renderObject(find.byKey(const ValueKey('bottom-nav-semantic-1')))
        .owner!
        .semanticsOwner!
        .performAction(node.id, ui.SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(h.selected.value, 1);
    semantics.dispose();
  });

  testWidgets('旧样式调用也保持完整的新液态底栏', (tester) async {
    final h = await pumpNav(tester);
    for (final style in [BottomNavStyle.normal, BottomNavStyle.floating]) {
      await h.theme.setBottomNavStyle(style);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bottom-nav-item-3')));
      await tester.pumpAndSettle();
      expect(h.selected.value, 3);
      expect(find.byType(LiquidGlassRenderer), findsOneWidget);
    }
    expect(h.commits, 2);
    expect(h.taps, 0);
  });
}

class NavHarness {
  NavHarness(this.theme, this.auth);
  final ThemeProvider theme;
  final AuthProvider auth;
  final selected = ValueNotifier(0);
  final position = ValueNotifier(0.0);
  final boundary = GlobalKey();
  int commits = 0, taps = 0;
  void dispose() {
    theme.dispose();
    auth.dispose();
    selected.dispose();
    position.dispose();
  }
}

Future<NavHarness> pumpNav(
  WidgetTester tester, {
  Size viewport = GoldenViewports.phone390x844,
  bool dark = false,
  bool reduced = false,
  double textScale = 1,
  bool withScope = true,
}) async {
  tester.view.devicePixelRatio = 1;
  await setGoldenViewport(tester, viewport);
  await tester.runAsync(() async {
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    await loadLiquidGlassProgram();
  });
  AppPreferencesStore.setMockInitialValues({});
  final theme = ThemeProvider(
      loadOnStart: false, performanceLevel: DevicePerformanceLevel.high);
  await theme.setBottomNavStyle(BottomNavStyle.liquidGlass);
  final h = NavHarness(theme, AuthProvider(Dio(), loadStoredAuth: false));
  addTearDown(h.dispose);
  await tester.pumpWidget(ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        home: Builder(
            builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                      disableAnimations: reduced,
                      textScaler: TextScaler.linear(textScale)),
                  child: RepaintBoundary(
                      key: h.boundary,
                      child: ValueListenableBuilder<int>(
                        valueListenable: h.selected,
                        builder: (context, selected, child) {
                          final content = ListView(
                              children: List.generate(
                                  30,
                                  (i) => SizedBox(
                                      height: 60,
                                      child: ColoredBox(
                                          color: i.isEven
                                              ? const Color(0xffb7dbe4)
                                              : const Color(0xffe9d7cc),
                                          child: Text('背景纹理 $i')))));
                          final scaffold = Scaffold(
                              extendBody: true,
                              body: withScope
                                  ? LiquidGlassBackground(child: content)
                                  : content,
                              bottomNavigationBar: BottomNavWrapper(
                                  currentIndex: selected,
                                  visualIndexListenable: h.position,
                                  onTap: (v) {
                                    h.taps++;
                                    h.selected.value = v;
                                  },
                                  onNavigationCommitted: (v) {
                                    h.commits++;
                                    h.selected.value = v;
                                  },
                                  authProvider: h.auth,
                                  badges: const {4: true}));
                          return withScope
                              ? LiquidGlassScope(child: scaffold)
                              : scaffold;
                        },
                      )),
                )),
      )));
  await tester.runAsync(() async {});
  await tester.pumpAndSettle();
  return h;
}

Future<void> snapshot(WidgetTester tester, NavHarness h, String name) async {
  final boundary =
      h.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/verification')..createSync(recursive: true);
    await File('${dir.path}/liquid-nav-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
