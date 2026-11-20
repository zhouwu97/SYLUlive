import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/bottom_navigation_settings_screen.dart';
import 'package:shenliyuan/widgets/floating_bottom_nav.dart';
import 'package:shenliyuan/widgets/liquid_bottom_nav.dart';

import '../../helpers/golden_viewport.dart';

class _FailingStore extends MemoryPreferencesStore {
  bool fail = false;

  @override
  Future<bool> setDouble(String key, double value) async {
    if (fail && key == 'bottom_nav_animation_intensity_v2') return false;
    return super.setDouble(key, value);
  }
}

class _ControlledStore extends MemoryPreferencesStore {
  final writes = <(String, Completer<bool>)>[];

  @override
  Future<bool> setString(String key, String value) async {
    if (key != 'bottom_nav_performance_mode_v2') {
      return super.setString(key, value);
    }
    final result = Completer<bool>();
    writes.add((value, result));
    if (!await result.future) return false;
    return super.setString(key, value);
  }
}

Widget _app(ThemeProvider theme, {bool dark = false, double scale = 1}) =>
    ChangeNotifierProvider.value(
      value: theme,
      child: MaterialApp(
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const BottomNavigationSettingsScreen(),
      ),
    );

Finder get _slider => find.descendant(
    of: find.byKey(const ValueKey('bottom-nav-intensity')),
    matching: find.byType(Slider));

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(find.text(label), 160,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(400, 800);
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
    AppPreferencesStore.setMockInitialValues({});
  });
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  testWidgets('侧栏预览拖动中收窄，取消旧手势并保留选择与控件状态', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.tabletPortrait834x1194);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    final previewState = tester.state(find.byType(LiquidBottomNav));
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-2'))));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 60));
    await setGoldenViewport(tester, GoldenViewports.phone390x844);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(LiquidBottomNav)), same(previewState));
    final preview =
        tester.widget<LiquidBottomNav>(find.byType(LiquidBottomNav));
    expect(preview.axis, Axis.horizontal);
    expect(preview.currentIndex, 2);
    expect(preview.visualIndexListenable.value, closeTo(2, .001));
    expect(find.text('底部导航栏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    GoldenViewports.tabletLandscape1280x800,
    GoldenViewports.tabletPortrait834x1194
  ]) {
    testWidgets('平板 $size 使用可纵向拖动的侧栏预览，关档和持久化仍生效', (tester) async {
      await setGoldenViewport(tester, size);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await tester.pumpWidget(_app(theme, dark: true, scale: 1.3));
      await tester.pumpAndSettle();
      expect(find.text('侧边导航栏'), findsOneWidget);
      expect(tester.widget<LiquidBottomNav>(find.byType(LiquidBottomNav)).axis,
          Axis.vertical);
      final start =
          tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-2')));
      final end =
          tester.getCenter(find.byKey(const ValueKey('bottom-nav-item-3')));
      expect(start.dx, end.dx);
      final gesture = await tester.startGesture(start);
      for (var i = 1; i <= 12; i++) {
        await gesture.moveTo(Offset.lerp(start, end, i / 12)!);
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
          tester
              .widget<LiquidBottomNav>(find.byType(LiquidBottomNav))
              .currentIndex,
          2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<LiquidBottomNav>(find.byType(LiquidBottomNav))
              .currentIndex,
          3);
      await _choose(tester, '关');
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('bottom-nav-preview-card')), -200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(
          tester.widget<FloatingBottomNav>(find.byType(FloatingBottomNav)).axis,
          Axis.vertical);
      expect(
          tester
              .widget<FloatingBottomNav>(find.byType(FloatingBottomNav))
              .currentIndex,
          3);
      await theme.loadThemeForTesting();
      expect(theme.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('关闭保留调节卡片，连续从 0 拖到 100 启用液态效果且不跳位', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setComponentOpacity(.43);
    await theme.setBackgroundBlur(8);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    double offset() =>
        tester.getTopLeft(_slider).dy +
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels;
    final before = offset();
    await _choose(tester, '关');
    expect(_slider, findsOneWidget);
    expect(tester.widget<Slider>(_slider).value, 0);
    expect(tester.widget<Slider>(_slider).onChanged, isNotNull);
    await tester.scrollUntilVisible(_slider, -160,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(offset(), before);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bottom-nav-preview-card')), -160,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingBottomNav), findsOneWidget);
    expect(find.byType(LiquidBottomNav), findsNothing);
    await tester.scrollUntilVisible(_slider, 160,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final state = tester.state(_slider);
    final rect = tester.getRect(_slider);
    final gesture =
        await tester.startGesture(Offset(rect.left + 24, rect.center.dy));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(theme.bottomNavShaderEnabled, isTrue);
    expect(tester.state(_slider), same(state));
    await gesture.moveTo(Offset(rect.right, rect.center.dy));
    await tester.pumpAndSettle();
    await gesture.moveTo(Offset(rect.left, rect.center.dy));
    await tester.pumpAndSettle();
    expect(theme.bottomNavAnimationIntensity, 0);
    expect(theme.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    expect(theme.bottomNavShaderEnabled, isFalse);
    expect(tester.state(_slider), same(state));
    expect(
        tester
            .widget<RadioGroup<BottomNavPerformanceMode>>(
                find.byType(RadioGroup<BottomNavPerformanceMode>))
            .groupValue,
        BottomNavPerformanceMode.off);
    await gesture.moveTo(Offset(rect.right, rect.center.dy));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(theme.bottomNavAnimationIntensity, 1);
    expect(
        theme.bottomNavPerformanceMode, BottomNavPerformanceMode.highQuality);
    expect(tester.state(_slider), same(state));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bottom-nav-preview-card')), -160,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.byType(LiquidBottomNav), findsOneWidget);
    expect(theme.componentOpacity, .43);
    expect(theme.backgroundBlur, 8);
    await theme.loadThemeForTesting();
    expect(theme.bottomNavAnimationIntensity, 1);
    expect(theme.bottomNavShaderEnabled, isTrue);
    await _choose(tester, '关');
    await theme.loadThemeForTesting();
    expect(theme.bottomNavAnimationIntensity, 0);
    expect(theme.bottomNavShaderEnabled, isFalse);
    expect(_slider, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败提示可重试最终手动强度，不重新套用其他预设', (tester) async {
    final store = _FailingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    store.fail = true;
    await _choose(tester, '高性能');
    expect(theme.bottomNavAnimationIntensity, .35);
    expect(find.text('液态效果设置未保存'), findsOneWidget);
    tester.widget<Slider>(_slider).onChanged!(.62);
    await tester.pumpAndSettle();
    expect(find.text('液态效果设置未保存'), findsOneWidget);
    store.fail = false;
    await _choose(tester, '液态效果设置未保存');
    expect(find.text('液态效果设置未保存'), findsNothing);
    expect(theme.bottomNavAnimationIntensity, .62);
    expect(store.getDouble('bottom_nav_animation_intensity_v2'), .62);
    expect(store.getString('bottom_nav_performance_mode_v2'), 'custom');
    expect(tester.takeException(), isNull);
  });

  test('关闭与拖动写入串行，较早保存失败不覆盖最终启用状态', () async {
    final store = _ControlledStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    final off = theme.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    final latest = theme.setBottomNavAnimationIntensity(.62);
    expect(theme.bottomNavAnimationIntensity, .62);
    expect(theme.bottomNavPerformanceMode, BottomNavPerformanceMode.custom);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes.map((entry) => entry.$1), ['off']);
    store.writes[0].$2.complete(false);
    expect(await off, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes.map((entry) => entry.$1), ['off', 'custom']);
    store.writes[1].$2.complete(true);
    expect(await latest, isTrue);
    expect(store.getString('bottom_nav_performance_mode_v2'), 'custom');
    expect(store.getDouble('bottom_nav_animation_intensity_v2'), .62);
    expect(await theme.setBottomNavAnimationIntensity(double.nan), isFalse);
    expect(theme.bottomNavAnimationIntensity, .62);
  });

  for (final viewport in [
    GoldenViewports.phone360x800,
    GoldenViewports.phone390x844
  ]) {
    for (final dark in [false, true]) {
      testWidgets('关闭面板 ${viewport.width}px dark=$dark 字体 130% 无溢出',
          (tester) async {
        await setGoldenViewport(tester, viewport);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
        await tester.pumpWidget(_app(theme, dark: dark, scale: 1.3));
        await tester.pumpAndSettle();
        expect(find.byType(FloatingBottomNav), findsOneWidget);
        await tester.scrollUntilVisible(_slider, 160,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(_slider).value, 0);
        final control = find.byKey(const ValueKey('bottom-nav-intensity'));
        final height = tester.getSize(control).height;
        await _choose(tester, '高画质');
        await tester.scrollUntilVisible(_slider, -160,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(tester.getSize(control).height, height);
        await _choose(tester, '关');
        expect(_slider, findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
