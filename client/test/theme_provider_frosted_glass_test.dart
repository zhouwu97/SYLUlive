import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

class _ControlledStore extends MemoryPreferencesStore {
  final writes = <(double, Completer<bool>)>[];

  @override
  Future<bool> setDouble(String key, double value) async {
    if (key != 'frosted_glass_strength') return super.setDouble(key, value);
    final result = Completer<bool>();
    writes.add((value, result));
    if (!await result.future) return false;
    return super.setDouble(key, value);
  }
}

class _OpacityWriteTrackingStore extends MemoryPreferencesStore {
  final opacityWrites = <double>[];

  @override
  Future<bool> setDouble(String key, double value) async {
    if (key == 'background_transparency') opacityWrites.add(value);
    return super.setDouble(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  test('旧设置兼容：默认保持 100%，开关不重置强度，重启恢复', () async {
    AppPreferencesStore.setMockInitialValues({
      'frosted_glass_enabled': true,
      'background_mode': 'custom',
      'background_image': 'morenbeijing.jpeg',
    });
    await AppPreferencesStore.getInstance();
    final theme = ThemeProvider();
    addTearDown(theme.dispose);
    expect(theme.frostedGlassStrength, 1);
    expect(theme.frostedGlass, isTrue);
    await theme.setFrostedGlassStrength(.35);
    await theme.setFrostedGlass(false);
    await theme.setFrostedGlass(true);
    expect(theme.frostedGlassStrength, .35);
    final restored = ThemeProvider();
    addTearDown(restored.dispose);
    expect(restored.frostedGlassStrength, .35);
    expect(restored.frostedGlassPresetLabel, '高性能');
  });

  for (final (stored, expected) in [
    (double.nan, 1.0),
    (double.infinity, 1.0),
    (-.1, 0.0),
    (1.2, 1.0),
    (.62, .62),
  ]) {
    test('同步及异步加载限制非法强度 $stored', () async {
      AppPreferencesStore.setMockInitialValues(
          {'frosted_glass_strength': stored});
      final asyncTheme = ThemeProvider(loadOnStart: false);
      addTearDown(asyncTheme.dispose);
      await asyncTheme.loadThemeForTesting();
      final syncTheme = ThemeProvider();
      addTearDown(syncTheme.dispose);
      expect(asyncTheme.frostedGlassStrength, expected);
      expect(syncTheme.frostedGlassStrength, expected);
    });
  }

  test('强度与壁纸模糊、不透明度、底栏独立，并规范化输入', () async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlass(true);
    await theme.setBackgroundBlur(12);
    await theme.setComponentOpacity(.6);
    await theme.setBottomNavAnimationIntensity(.4);
    await theme.setFrostedGlassStrength(.624);
    expect(theme.frostedGlassStrength, .62);
    expect(theme.frostedGlassPresetLabel, '自定义');
    expect(theme.backgroundBlur, 12);
    expect(theme.componentOpacity, .6);
    expect(theme.bottomNavAnimationIntensity, .4);
    expect(await theme.setFrostedGlassStrength(double.nan), isFalse);
    expect(theme.frostedGlassStrength, .62);
    await theme.setFrostedGlassStrength(-1);
    expect(theme.frostedGlassStrength, 0);
    await theme.setFrostedGlassStrength(2);
    expect(theme.frostedGlassStrength, 1);
  });

  test('四档选择控制毛玻璃并填入不透明度，自定义强度为 65%', () async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    await theme.setComponentOpacity(.43);
    await theme.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highPerformance);
    expect(theme.frostedGlass, isTrue);
    expect(theme.frostedGlassStrength, .35);
    await theme.setFrostedGlassStrength(.62);
    expect(
        theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    await theme.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highQuality);
    expect(theme.frostedGlassStrength, 1);
    await theme.setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.off);
    expect(theme.frostedGlass, isFalse);
    expect(theme.frostedGlassStrength, 0);
    final restored = ThemeProvider(loadOnStart: false);
    addTearDown(restored.dispose);
    await restored.loadThemeForTesting();
    expect(
        restored.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    expect(restored.componentOpacity, 1);
    expect(restored.frostedGlassStrength, 0);
    await restored
        .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
    expect(restored.frostedGlassStrength, .65);
    expect(restored.frostedGlass, isTrue);
    await restored.setFrostedGlassStrength(0);
    expect(
        restored.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    expect(restored.frostedGlass, isFalse);
  });

  test('预设填入 100% 或 75%，手动不透明度跨重启及重试保留', () async {
    final store = _OpacityWriteTrackingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    for (final mode in FrostedGlassPerformanceMode.values) {
      await theme.setComponentOpacity(.43);
      store.opacityWrites.clear();
      final expected = mode == FrostedGlassPerformanceMode.off ? 1.0 : .75;
      await theme.setFrostedGlassPerformanceMode(mode);
      expect(theme.componentOpacity, expected);
      expect(store.getDouble('background_transparency'), expected);
      expect(store.opacityWrites, [expected]);
      await theme.setComponentOpacity(.46);
      await theme.setFrostedGlassPerformanceMode(mode);
      expect(theme.componentOpacity, expected, reason: '重复选择也应填入预设值');
      await theme.setComponentOpacity(.32);
      await theme.saveFrostedGlassSettings(includeOpacity: true);
      expect(theme.componentOpacity, .32, reason: '重试保存当前值而不是重新套用预设');
      expect(store.getDouble('background_transparency'), .32);
    }
    await theme.setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.off);
    await theme.setComponentOpacity(.32);
    final restored = ThemeProvider(loadOnStart: false);
    addTearDown(restored.dispose);
    await restored.loadThemeForTesting();
    expect(restored.componentOpacity, .32);
    expect(restored.frostedGlass, isFalse);
  });

  test('预设写入尚未完成时手动拖动，最终存储以手动不透明度为准', () async {
    final store = _ControlledStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    final preset = theme.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highPerformance);
    final manual = theme.setComponentOpacity(.46);
    expect(theme.componentOpacity, .46);
    await Future<void>.delayed(Duration.zero);
    store.writes.single.$2.complete(true);
    expect(await preset, isTrue);
    expect(await manual, isTrue);
    expect(store.getDouble('background_transparency'), .46);
    expect(store.getDouble('frosted_glass_strength'), .35);
  });

  test('历史自定义记忆不覆盖 65% 预设，手动强度仍跨重启恢复', () async {
    for (final custom in [
      double.nan,
      double.infinity,
      -.1,
      1.2,
      .35,
      1.0,
      .51
    ]) {
      AppPreferencesStore.setMockInitialValues({
        'frosted_glass_strength': .62,
        'frosted_glass_custom_strength': custom,
      });
      final theme = ThemeProvider(loadOnStart: false);
      await theme.loadThemeForTesting();
      expect(theme.frostedGlassStrength, .62);
      await theme
          .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
      expect(theme.frostedGlassStrength, .65);
      await theme.setFrostedGlassStrength(.51);
      final restored = ThemeProvider(loadOnStart: false);
      await restored.loadThemeForTesting();
      expect(restored.frostedGlassStrength, .51);
      await restored
          .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
      expect(restored.frostedGlassStrength, .65);
      theme.dispose();
      restored.dispose();
    }
  });

  test('手动零强度关闭并跨重启恢复，不重设卡片不透明度', () async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    await theme.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highQuality);
    await theme.setComponentOpacity(.43);
    await theme.setFrostedGlassStrength(.004);
    expect(theme.frostedGlassStrength, 0);
    expect(theme.frostedGlass, isFalse);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    expect(theme.componentOpacity, .43);
    final restored = ThemeProvider(loadOnStart: false);
    addTearDown(restored.dispose);
    await restored.loadThemeForTesting();
    expect(restored.frostedGlass, isFalse);
    expect(
        restored.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
    expect(restored.componentOpacity, .43);
    await restored.setFrostedGlassStrength(.35);
    expect(restored.frostedGlassPerformanceMode,
        FrostedGlassPerformanceMode.highPerformance);
    expect(restored.frostedGlass, isTrue);
    expect(restored.componentOpacity, .43);
  });

  test('旧零强度自定义记录在同步和异步加载后均匹配关闭', () async {
    AppPreferencesStore.setMockInitialValues({
      'frosted_glass_enabled': true,
      'frosted_glass_strength': 0.0,
      'bottom_nav_performance_mode_v2': 'custom',
      'bottom_nav_animation_intensity_v2': 0.0,
      'bottom_nav_custom_intensity': 0.0,
      'background_transparency': .43,
    });
    final asyncTheme = ThemeProvider(loadOnStart: false);
    addTearDown(asyncTheme.dispose);
    await asyncTheme.loadThemeForTesting();
    final syncTheme = ThemeProvider();
    addTearDown(syncTheme.dispose);
    for (final theme in [asyncTheme, syncTheme]) {
      expect(theme.frostedGlass, isFalse);
      expect(
          theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
      expect(theme.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
      expect(theme.bottomNavShaderEnabled, isFalse);
      expect(theme.componentOpacity, .43);
    }
    await asyncTheme
        .setBottomNavPerformanceMode(BottomNavPerformanceMode.custom);
    expect(asyncTheme.bottomNavAnimationIntensity, .65);
    await asyncTheme.setBottomNavAnimationIntensity(.004);
    expect(asyncTheme.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    expect(asyncTheme.bottomNavShaderEnabled, isFalse);
    await asyncTheme.loadThemeForTesting();
    expect(asyncTheme.bottomNavPerformanceMode, BottomNavPerformanceMode.off);
    await asyncTheme
        .setBottomNavPerformanceMode(BottomNavPerformanceMode.custom);
    expect(asyncTheme.bottomNavAnimationIntensity, .65);
  });

  test('快速拖动立即预览，写入串行且最终值胜出，保存失败可重试', () async {
    final store = _ControlledStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    final first = theme.setFrostedGlassStrength(.35);
    final last = theme.setFrostedGlassStrength(.62);
    expect(theme.frostedGlassStrength, .62);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes.map((w) => w.$1), [.35]);
    store.writes[0].$2.complete(false);
    expect(await first, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes.map((w) => w.$1), [.35, .62]);
    store.writes[1].$2.complete(false);
    expect(await last, isFalse);
    final retry = theme.setFrostedGlassStrength(.62);
    await Future<void>.delayed(Duration.zero);
    store.writes[2].$2.complete(true);
    expect(await retry, isTrue);
    expect(store.getDouble('frosted_glass_strength'), .62);
    expect(theme.frostedGlassStrength, .62);
  });
}
