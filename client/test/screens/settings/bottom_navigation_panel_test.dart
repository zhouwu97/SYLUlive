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
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

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
