import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';

class _ControlledStore extends MemoryPreferencesStore {
  Completer<void>? firstWrite;
  String? failedKey;
  bool throwOnFailure = false;
  final writes = <(String, bool)>[];

  @override
  Future<bool> setBool(String key, bool value) async {
    writes.add((key, value));
    final pending = firstWrite;
    firstWrite = null;
    if (pending != null) await pending.future;
    if (key == failedKey) {
      if (throwOnFailure) throw StateError('storage unavailable');
      return false;
    }
    return super.setBool(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  for (final (values, expected) in [
    (<String, Object>{}, ThemeMode.system),
    ({'night_mode': true}, ThemeMode.system),
    ({'night_mode': true, 'night_mode_follow_system': true}, ThemeMode.system),
    ({'night_mode': true, 'night_mode_follow_system': false}, ThemeMode.dark),
    ({'night_mode': false, 'night_mode_follow_system': false}, ThemeMode.light),
  ]) {
    test('旧设置 $values 在同步和异步加载时均恢复 $expected', () async {
      AppPreferencesStore.setMockInitialValues(values);
      final asyncTheme = ThemeProvider(loadOnStart: false);
      addTearDown(asyncTheme.dispose);
      await asyncTheme.loadThemeForTesting();
      final syncTheme = ThemeProvider();
      addTearDown(syncTheme.dispose);
      expect(asyncTheme.themeMode, expected);
      expect(syncTheme.themeMode, expected);
    });
  }

  test('三种模式双向切换立即生效并可重启恢复，跟随系统保留手动偏好', () async {
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    final changes = <ThemeMode>[];
    theme.addListener(() => changes.add(theme.themeMode));

    for (final mode in [
      ThemeMode.dark,
      ThemeMode.system,
      ThemeMode.light,
      ThemeMode.dark,
      ThemeMode.light,
      ThemeMode.system,
    ]) {
      final save = theme.setThemeMode(mode);
      expect(theme.themeMode, mode);
      expect(changes.last, mode);
      expect(await save, isTrue);
      final restored = ThemeProvider();
      expect(restored.themeMode, mode);
      restored.dispose();
    }

    await theme.setDarkMode(true);
    await theme.setFollowSystem(true);
    expect(theme.themeMode, ThemeMode.system);
    await theme.setFollowSystem(false);
    expect(theme.themeMode, ThemeMode.dark);
    await theme.toggleTheme();
    expect(theme.themeMode, ThemeMode.light);
  });

  test('快速切换按调用顺序保存快照，旧写入不能覆盖最后一次选择', () async {
    final pending = Completer<void>();
    final store = _ControlledStore()..firstWrite = pending;
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);

    final dark = theme.setThemeMode(ThemeMode.dark);
    final light = theme.setThemeMode(ThemeMode.light);
    final system = theme.setThemeMode(ThemeMode.system);
    expect(theme.themeMode, ThemeMode.system);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, [('night_mode', true)]);
    pending.complete();
    expect(await Future.wait([dark, light, system]), [true, true, true]);
    expect(store.writes, [
      ('night_mode', true),
      ('night_mode_follow_system', false),
      ('night_mode', false),
      ('night_mode_follow_system', false),
      ('night_mode', false),
      ('night_mode_follow_system', true),
    ]);
    final restored = ThemeProvider();
    addTearDown(restored.dispose);
    expect(restored.themeMode, ThemeMode.system);
  });

  test('初始化晚到不会覆盖用户选择', () async {
    await AppPreferencesStore.getInstance();
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    final loading = theme.loadThemeForTesting();
    final saving = theme.setThemeMode(ThemeMode.dark);
    await loading;
    expect(theme.isLoaded, isTrue);
    expect(theme.themeMode, ThemeMode.dark);
    expect(await saving, isTrue);
  });

  for (final key in ['night_mode', 'night_mode_follow_system']) {
    for (final throws in [false, true]) {
      test('$key 保存${throws ? '抛错' : '返回失败'}后可重试，队列继续工作', () async {
        final store = _ControlledStore()
          ..failedKey = key
          ..throwOnFailure = throws;
        AppPreferencesStore.setCustomInstance(store);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        expect(await theme.setThemeMode(ThemeMode.dark), isFalse);
        expect(theme.themeMode, ThemeMode.dark);
        store.failedKey = null;
        expect(await theme.setThemeMode(ThemeMode.dark), isTrue);
        final restored = ThemeProvider();
        addTearDown(restored.dispose);
        expect(restored.themeMode, ThemeMode.dark);
      });
    }
  }
}
