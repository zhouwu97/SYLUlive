import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/frosted_glass_settings_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/settings/settings_effect_option.dart';
import 'package:shenliyuan/widgets/settings/settings_effect_preview.dart';
import 'package:shenliyuan/widgets/settings/settings_tile.dart';

import '../../helpers/golden_viewport.dart';

class _FailingStore extends MemoryPreferencesStore {
  final failedKeys = <String>{};

  @override
  Future<bool> setDouble(String key, double value) async {
    if (failedKeys.contains(key)) throw StateError('storage unavailable');
    return super.setDouble(key, value);
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
        home: const FrostedGlassSettingsScreen(),
      ),
    );

Finder _slider(String key) => find.descendant(
    of: find.byKey(ValueKey(key)), matching: find.byType(Slider));

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(find.text(label), 140,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  testWidgets('卡片参数合并，无独立预览和开关，四档预设填入不透明度', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setComponentOpacity(.7);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    expect(find.text('卡片外观'), findsOneWidget);
    expect(find.text('效果预设'), findsOneWidget);
    expect(find.text('毛玻璃效果'), findsNothing);
    expect(find.byType(SettingsEffectPreview), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(SettingsEffectOption<FrostedGlassPerformanceMode>),
        findsNWidgets(4));
    expect(tester.widget<Slider>(_slider('card-opacity')).onChanged, isNotNull);
    expect(theme.componentOpacity, .7);
    expect(_slider('card-blur-strength'), findsOneWidget);
    expect(tester.widget<Slider>(_slider('card-blur-strength')).value, 0);
    await _choose(tester, '高性能');
    expect(theme.frostedGlass, isTrue);
    expect(theme.frostedGlassStrength, .35);
    expect(tester.widget<Slider>(_slider('card-opacity')).onChanged, isNotNull);
    await tester.ensureVisible(_slider('card-opacity'));
    await tester.pumpAndSettle();
    await tester.drag(_slider('card-opacity'), const Offset(-70, 0));
    await tester.pumpAndSettle();
    final opacity = theme.componentOpacity;
    expect(opacity, lessThan(.75));
    tester.widget<Slider>(_slider('card-blur-strength')).onChanged!(.62);
    await tester.pumpAndSettle();
    expect(
        theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    await _choose(tester, '高画质');
    expect(theme.frostedGlassStrength, 1);
    expect(theme.componentOpacity, .75);
    await _choose(tester, '自定义');
    expect(theme.frostedGlassStrength, .65);
    Offset controlsOffset() =>
        tester.getTopLeft(_slider('card-blur-strength')) -
        tester.getTopLeft(_slider('card-opacity'));
    final controlsBeforeOff = controlsOffset();
    await _choose(tester, '关');
    expect(controlsOffset(), controlsBeforeOff);
    expect(theme.frostedGlassStrength, 0);
    expect(theme.frostedGlass, isFalse);
    expect(theme.componentOpacity, 1);
    expect(_slider('card-blur-strength'), findsOneWidget);
    expect(tester.widget<Slider>(_slider('card-blur-strength')).value, 0);
    await _choose(tester, '自定义');
    expect(theme.frostedGlassStrength, .65);
    expect(theme.componentOpacity, .75);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getBool('frosted_glass_enabled'), isTrue);
    expect(prefs.getDouble('frosted_glass_strength'), .65);
    expect(prefs.getDouble('background_transparency'), .75);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预设填入不透明度，手动调节在开关毛玻璃两种状态都影响底面', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highQuality);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    final card = find
        .ancestor(
            of: find.byKey(const ValueKey('card-opacity')),
            matching: find.byType(AppCardSurface))
        .first;
    Color surface() => (tester
            .widget<DecoratedBox>(find
                .descendant(of: card, matching: find.byType(DecoratedBox))
                .first)
            .decoration as BoxDecoration)
        .color!;
    for (final opacity in [.4, .8]) {
      tester.widget<Slider>(_slider('card-opacity')).onChanged!(opacity);
      await tester.pumpAndSettle();
      expect(surface().a, closeTo(opacity, .01));
      for (final strength in [0.0, .35, 1.0]) {
        tester
            .widget<Slider>(_slider('card-blur-strength'))
            .onChanged!(strength);
        await tester.pumpAndSettle();
        expect(surface().a, closeTo(opacity, .01));
      }
    }
    await _choose(tester, '关');
    expect(surface().a, 1);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is BackdropFilter && widget.enabled),
        findsNothing);
    expect(theme.componentOpacity, 1);
    tester.widget<Slider>(_slider('card-opacity')).onChanged!(.45);
    await tester.pumpAndSettle();
    expect(surface().a, closeTo(.45, .01));
    expect(theme.frostedGlass, isFalse);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is BackdropFilter && widget.enabled),
        findsNothing);
    await _choose(tester, '高性能');
    expect(surface().a, closeTo(.75, .01));
    expect(theme.frostedGlassStrength, .35);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭时面板保留，从 0% 连续拖到 100% 启用毛玻璃且不中断手势', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.off);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    final slider = _slider('card-blur-strength');
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final state = tester.state(slider);
    final rect = tester.getRect(slider);
    final gesture =
        await tester.startGesture(Offset(rect.left + 24, rect.center.dy));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(tester.state(slider), same(state));
    await gesture.moveTo(Offset(rect.right, rect.center.dy));
    await tester.pumpAndSettle();
    await gesture.moveTo(Offset(rect.left, rect.center.dy));
    await tester.pumpAndSettle();
    expect(theme.frostedGlassStrength, 0);
    expect(theme.frostedGlass, isFalse);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    expect(theme.componentOpacity, 1);
    expect(tester.state(slider), same(state));
    expect(
        tester
            .widget<RadioGroup<FrostedGlassPerformanceMode>>(
                find.byType(RadioGroup<FrostedGlassPerformanceMode>))
            .groupValue,
        FrostedGlassPerformanceMode.off);
    await gesture.moveTo(Offset(rect.right, rect.center.dy));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(theme.frostedGlassStrength, 1);
    expect(theme.frostedGlass, isTrue);
    expect(theme.componentOpacity, 1);
    expect(theme.frostedGlassPerformanceMode,
        FrostedGlassPerformanceMode.highQuality);
    expect(tester.state(slider), same(state));
    final restored = ThemeProvider(loadOnStart: false);
    addTearDown(restored.dispose);
    await restored.loadThemeForTesting();
    expect(restored.frostedGlass, isTrue);
    expect(restored.frostedGlassStrength, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败分别提示和重试，另一项成功不会掩盖错误', (tester) async {
    final store = _FailingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    store.failedKeys
        .addAll(['background_transparency', 'frosted_glass_strength']);
    tester.widget<Slider>(_slider('card-opacity')).onChanged!(.55);
    tester.widget<Slider>(_slider('card-blur-strength')).onChanged!(.62);
    await tester.pumpAndSettle();
    expect(find.text('不透明度未保存'), findsOneWidget);
    expect(find.text('毛玻璃设置未保存'), findsOneWidget);
    expect(theme.componentOpacity, .55);
    expect(theme.frostedGlassStrength, .62);
    store.failedKeys.remove('frosted_glass_strength');
    await _choose(tester, '毛玻璃设置未保存');
    expect(find.text('毛玻璃设置未保存'), findsNothing);
    expect(find.text('不透明度未保存'), findsOneWidget);
    store.failedKeys.clear();
    await _choose(tester, '不透明度未保存');
    expect(find.text('不透明度未保存'), findsNothing);
    expect(store.getDouble('background_transparency'), .55);
    expect(store.getDouble('frosted_glass_strength'), .62);
    expect(tester.takeException(), isNull);
  });

  testWidgets('简洁背景禁用不透明度、毛玻璃滑块和预设，切回背景恢复原设置', (tester) async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme
        .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
    await theme.setComponentOpacity(.43);
    await theme.setCleanBackgroundMode();
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(_slider('card-opacity')).onChanged, isNull);
    expect(
        tester.widget<Slider>(_slider('card-blur-strength')).onChanged, isNull);
    expect(tester.widget<Slider>(_slider('card-blur-strength')).value, 0);
    expect(theme.frostedGlass, isFalse);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    expect(find.text('仅在自定义背景模式下生效'), findsNWidgets(2));
    final options =
        tester.widgetList<SettingsEffectOption<FrostedGlassPerformanceMode>>(
            find.byType(SettingsEffectOption<FrostedGlassPerformanceMode>));
    expect(options.every((option) => !option.enabled), isTrue);
    await _choose(tester, '高性能');
    expect(theme.frostedGlass, isFalse);
    expect(theme.frostedGlassStrength, .65);
    expect(theme.componentOpacity, .43);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getBool('frosted_glass_enabled'), isTrue);
    expect(prefs.getDouble('frosted_glass_strength'), .65);
    await theme.trySetCustomBackgroundMode();
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(_slider('card-blur-strength')).onChanged,
        isNotNull);
    expect(theme.frostedGlass, isTrue);
    expect(
        theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    expect(theme.frostedGlassStrength, .65);
    expect(theme.componentOpacity, .43);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败后切到简洁模式禁用重试，返回自定义背景可恢复保存', (tester) async {
    final store = _FailingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    store.failedKeys.add('frosted_glass_strength');
    tester.widget<Slider>(_slider('card-blur-strength')).onChanged!(.62);
    await tester.pumpAndSettle();
    final retry = find.widgetWithText(SettingsTile, '毛玻璃设置未保存');
    expect(retry, findsOneWidget);
    await theme.setCleanBackgroundMode();
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsTile>(retry).enabled, isFalse);
    expect(find.text('切换到自定义背景后可重试保存'), findsOneWidget);
    expect(theme.frostedGlass, isFalse);
    store.failedKeys.clear();
    await theme.trySetCustomBackgroundMode();
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsTile>(retry).enabled, isTrue);
    await _choose(tester, '毛玻璃设置未保存');
    expect(retry, findsNothing);
    expect(theme.frostedGlass, isTrue);
    expect(store.getDouble('frosted_glass_strength'), .62);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预设不透明度保存失败不被后续强度保存掩盖，重试保留手动值', (tester) async {
    final store = _FailingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await tester.pumpWidget(_app(theme));
    await tester.pumpAndSettle();
    store.failedKeys.add('background_transparency');
    await _choose(tester, '自定义');
    expect(theme.componentOpacity, .75);
    expect(theme.frostedGlassStrength, .65);
    expect(find.text('毛玻璃设置未保存'), findsOneWidget);
    tester.widget<Slider>(_slider('card-opacity')).onChanged!(.46);
    tester.widget<Slider>(_slider('card-blur-strength')).onChanged!(.6);
    await tester.pumpAndSettle();
    expect(find.text('毛玻璃设置未保存'), findsOneWidget);
    expect(find.text('不透明度未保存'), findsOneWidget);
    store.failedKeys.clear();
    await _choose(tester, '毛玻璃设置未保存');
    expect(theme.componentOpacity, .46);
    expect(theme.frostedGlassStrength, .6);
    expect(store.getDouble('background_transparency'), .46);
    expect(store.getDouble('frosted_glass_strength'), .6);
    expect(find.text('毛玻璃设置未保存'), findsNothing);
    await _choose(tester, '不透明度未保存');
    expect(find.text('不透明度未保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in [
    GoldenViewports.phone360x800,
    GoldenViewports.phone390x844
  ]) {
    for (final dark in [false, true]) {
      testWidgets('${viewport.width}px 与 130% 字体无溢出 dark=$dark',
          (tester) async {
        await setGoldenViewport(tester, viewport);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg');
        await theme.setFrostedGlass(true);
        await tester.pumpWidget(_app(theme, dark: dark, scale: 1.3));
        await tester.pumpAndSettle();
        await _choose(tester, '高画质');
        expect(theme.frostedGlassStrength, 1);
        await _choose(tester, '关');
        expect(_slider('card-blur-strength'), findsOneWidget);
        expect(tester.widget<Slider>(_slider('card-blur-strength')).value, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
