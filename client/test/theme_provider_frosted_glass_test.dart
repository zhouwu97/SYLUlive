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

  test('新刻度线性映射 0% 到 75%、50% 到 87.5%、100% 到实色并跨重启恢复', () async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    final prefs = await AppPreferencesStore.getInstance();
    for (final (level, opacity) in [
      (-1.0, .75),
      (0.0, .75),
      (.25, .8125),
      (.5, .875),
      (.75, .9375),
      (1.0, 1.0),
      (2.0, 1.0),
    ]) {
      expect(await theme.setComponentOpacityLevel(level), isTrue);
      expect(theme.componentOpacity, opacity);
      expect(theme.effectiveComponentOpacity, opacity);
      expect(theme.componentOpacityLevel, level.clamp(0.0, 1.0));
      expect(prefs.getDouble('background_transparency'), opacity);
      final restored = ThemeProvider(loadOnStart: false);
      addTearDown(restored.dispose);
      await restored.loadThemeForTesting();
      expect(restored.componentOpacityLevel, theme.componentOpacityLevel);
      expect(restored.effectiveComponentOpacity, opacity);
    }
    for (final invalid in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(await theme.setComponentOpacityLevel(invalid), isFalse);
      expect(theme.componentOpacityLevel, 1);
      expect(prefs.getDouble('background_transparency'), 1);
    }
  });

  for (final (stored, level) in [
    (.1, 0.0),
    (.75, 0.0),
    (.875, .5),
    (.95, .8),
    (1.0, 1.0),
    (-.1, 0.0),
    (1.2, 1.0),
    (double.nan, 1.0),
    (double.infinity, 1.0),
  ]) {
    test('同步和异步读取历史不透明度 $stored 换算为新档位 $level', () async {
      AppPreferencesStore.setMockInitialValues({
        'background_mode': 'custom',
        'background_image': 'morenbeijing.jpeg',
        'background_transparency': stored,
      });
      final asyncTheme = ThemeProvider(loadOnStart: false);
      addTearDown(asyncTheme.dispose);
      await asyncTheme.loadThemeForTesting();
      final syncTheme = ThemeProvider();
      addTearDown(syncTheme.dispose);
      for (final theme in [asyncTheme, syncTheme]) {
        expect(theme.componentOpacityLevel, closeTo(level, 1e-12));
        expect(theme.effectiveComponentOpacity, closeTo(.75 + .25 * level, 1e-12));
      }
    });
  }

  test('历史低不透明度对应新的最低档，切换背景和重启保留偏好', () async {
    AppPreferencesStore.setMockInitialValues({
      'background_mode': 'custom',
      'background_image': 'morenbeijing.jpeg',
      'background_transparency': .1,
    });
    await AppPreferencesStore.getInstance();
    final theme = ThemeProvider();
    addTearDown(theme.dispose);
    expect(theme.componentOpacity, .1);
    expect(theme.effectiveComponentOpacity, .75);
    for (final glass in [true, false]) {
      await theme.setFrostedGlass(glass);
      expect(theme.effectiveComponentOpacity, .75);
    }
    await theme.setCleanBackgroundMode();
    expect(theme.effectiveComponentOpacity, 1);
    await theme.trySetCustomBackgroundMode();
    expect(theme.effectiveComponentOpacity, .75);
    expect(await theme.setComponentOpacity(.2), isTrue);
    final restored = ThemeProvider(loadOnStart: false);
    addTearDown(restored.dispose);
    await restored.loadThemeForTesting();
    expect(restored.componentOpacity, .2);
    expect(restored.effectiveComponentOpacity, .75);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getDouble('background_transparency'), .2);
  });

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
    expect(restored.frostedGlassPresetLabel, '自定义',
        reason: '旧记录的不透明度为 100%，与高性能预设的 75% 不匹配');
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

  test('四档选择控制毛玻璃并填入不透明度，自定义预设恢复上一次手动保存值（默认 65%）', () async {
    final fresh = ThemeProvider(loadOnStart: false);
    addTearDown(fresh.dispose);
    await fresh.setBackgroundImage('morenbeijing.jpeg');
    await fresh
        .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
    expect(fresh.frostedGlassStrength, .65, reason: '无历史手动保存时默认 65%');

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
    expect(restored.frostedGlassStrength, .62, reason: '恢复上一次手动保存的预设值');
    expect(restored.frostedGlass, isTrue);
    await restored.setFrostedGlassStrength(0);
    expect(
        restored.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    expect(restored.frostedGlass, isFalse);
  });

  test('三档固定预设联动新刻度和模糊，自定义预设恢复手动不透明度', () async {
    final store = _OpacityWriteTrackingStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    for (final (mode, level, expected, strength) in [
      (FrostedGlassPerformanceMode.off, 1.0, 1.0, 0.0),
      (FrostedGlassPerformanceMode.highPerformance, .75, .9375, .35),
      (FrostedGlassPerformanceMode.highQuality, 0.0, .75, 1.0),
    ]) {
      await theme.setComponentOpacity(.43);
      store.opacityWrites.clear();
      await theme.setFrostedGlassPerformanceMode(mode);
      expect(theme.componentOpacityLevel, level);
      expect(theme.componentOpacity, expected);
      expect(theme.effectiveComponentOpacity, expected);
      expect(theme.frostedGlassStrength, strength);
      expect(theme.frostedGlassPerformanceMode, mode);
      expect(store.getDouble('background_transparency'), expected);
      expect(store.opacityWrites, [expected]);
      final restoredPreset = ThemeProvider(loadOnStart: false);
      await restoredPreset.loadThemeForTesting();
      expect(restoredPreset.componentOpacityLevel, level);
      expect(restoredPreset.frostedGlassStrength, strength);
      expect(restoredPreset.frostedGlassPerformanceMode, mode);
      restoredPreset.dispose();
      await theme.setComponentOpacity(.46);
      await theme.setFrostedGlassPerformanceMode(mode);
      expect(theme.componentOpacity, expected, reason: '重复选择也应填入预设值');
      await theme.setComponentOpacity(.32);
      await theme.saveFrostedGlassSettings(includeOpacity: true);
      expect(theme.componentOpacity, .32, reason: '重试保存当前值而不是重新套用预设');
      expect(store.getDouble('background_transparency'), .32);
    }
    final freshTheme = ThemeProvider(loadOnStart: false);
    addTearDown(freshTheme.dispose);
    await freshTheme.setBackgroundImage('morenbeijing.jpeg');
    await freshTheme
        .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
    expect(freshTheme.componentOpacityLevel, closeTo(.65, 1e-6));
    expect(freshTheme.componentOpacity, closeTo(.9125, 1e-12));
    expect(freshTheme.frostedGlassStrength, .65);

    await freshTheme.setComponentOpacityLevel(.5);
    await freshTheme.setFrostedGlassStrength(.65);
    await freshTheme
        .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.highQuality);
    await freshTheme
        .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
    expect(freshTheme.componentOpacityLevel, .5);
    expect(freshTheme.componentOpacity, .875);
    expect(freshTheme.frostedGlassStrength, .65);

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
    await theme.setBackgroundImage('morenbeijing.jpeg');
    final preset = theme.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highPerformance);
    final manual = theme.setComponentOpacityLevel(.46);
    expect(theme.componentOpacity, .865);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    await Future<void>.delayed(Duration.zero);
    store.writes.single.$2.complete(true);
    expect(await preset, isTrue);
    expect(await manual, isTrue);
    expect(store.getDouble('background_transparency'), .865);
    expect(store.getDouble('frosted_glass_strength'), .35);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
  });

  for (final preset in [
    FrostedGlassPerformanceMode.off,
    FrostedGlassPerformanceMode.highPerformance,
    FrostedGlassPerformanceMode.highQuality,
  ]) {
    test('${preset.label}调整不透明度后匹配自定义，重启恢复并可重新匹配预设', () async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme.setFrostedGlassPerformanceMode(preset);
      final presetLevel = theme.componentOpacityLevel;
      final strength = theme.frostedGlassStrength;
      final enabled = theme.frostedGlass;
      expect(theme.frostedGlassPerformanceMode, preset);

      await theme.setComponentOpacityLevel(.46);
      expect(
          theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
      expect(theme.frostedGlassStrength, strength);
      expect(theme.frostedGlass, enabled);
      final restored = ThemeProvider(loadOnStart: false);
      addTearDown(restored.dispose);
      await restored.loadThemeForTesting();
      expect(restored.frostedGlassPerformanceMode,
          FrostedGlassPerformanceMode.custom);
      expect(restored.componentOpacity, .865);
      expect(restored.frostedGlassStrength, strength);
      expect(restored.frostedGlass, enabled);

      await restored.setCleanBackgroundMode();
      expect(
          restored.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
      await restored.trySetCustomBackgroundMode();
      expect(restored.frostedGlassPerformanceMode,
          FrostedGlassPerformanceMode.custom);
      await restored.setComponentOpacityLevel(presetLevel);
      expect(restored.frostedGlassPerformanceMode, preset);
    });
  }

  test('历史自定义记忆作为自定义预设恢复，无有效记忆时为 65%', () async {
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
        'custom_component_opacity_level': custom,
      });
      final theme = ThemeProvider(loadOnStart: false);
      await theme.loadThemeForTesting();
      expect(theme.frostedGlassStrength, .62);
      await theme
          .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
      final expectedCustom = custom.isFinite && custom > 0 && custom <= 1.0
          ? (custom * 100).round() / 100
          : .65;
      expect(theme.frostedGlassStrength, expectedCustom);
      expect(theme.componentOpacityLevel, closeTo(expectedCustom, 1e-6));
      await theme.setFrostedGlassStrength(.51);
      await theme.setComponentOpacityLevel(.51);
      final restored = ThemeProvider(loadOnStart: false);
      await restored.loadThemeForTesting();
      expect(restored.frostedGlassStrength, .51);
      expect(restored.componentOpacityLevel, closeTo(.51, 1e-6));
      await restored
          .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
      expect(restored.frostedGlassStrength, .51);
      expect(restored.componentOpacityLevel, closeTo(.51, 1e-6));
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
    await theme.setComponentOpacityLevel(.43);
    await theme.setFrostedGlassStrength(.004);
    expect(theme.frostedGlassStrength, 0);
    expect(theme.frostedGlass, isFalse);
    expect(theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    expect(theme.componentOpacity, .8575);
    final restored = ThemeProvider(loadOnStart: false);
    addTearDown(restored.dispose);
    await restored.loadThemeForTesting();
    expect(restored.frostedGlass, isFalse);
    expect(
        restored.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.custom);
    expect(restored.componentOpacity, .8575);
    await restored.setFrostedGlassStrength(.35);
    expect(restored.frostedGlassPerformanceMode,
        FrostedGlassPerformanceMode.custom);
    expect(restored.frostedGlass, isTrue);
    expect(restored.componentOpacity, .8575);
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
