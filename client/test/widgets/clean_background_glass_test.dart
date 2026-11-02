import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/frosted_glass.dart';

import '../helpers/active_backdrop_filters.dart';

class _DelayedStore extends MemoryPreferencesStore {
  Completer<bool>? gate;

  @override
  Future<bool> setDouble(String key, double value) async {
    final pending = gate;
    if (key == 'frosted_glass_strength' &&
        pending != null &&
        !await pending.future) {
      return false;
    }
    return super.setDouble(key, value);
  }
}

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  for (final dark in [false, true]) {
    testWidgets('简洁模式停用所有共享卡片和显式滤镜，切回背景恢复 dark=$dark', (tester) async {
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg');
      await theme
          .setFrostedGlassPerformanceMode(FrostedGlassPerformanceMode.custom);
      await theme.setComponentOpacity(.43);
      await theme.setBottomNavPerformanceMode(
          BottomNavPerformanceMode.highPerformance);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(
              body: Column(children: [
            AppCardSurface(
                child: const SizedBox(
                    key: Key('surface'), height: 40, width: 100)),
            const AppCard(
                child: SizedBox(key: Key('card'), height: 40, width: 100)),
            const AppCardMaterial(
                child: SizedBox(key: Key('material'), height: 40, width: 100)),
            const ClipRect(
                child: FrostedGlass(
                    enabled: true,
                    child: SizedBox(
                        key: Key('explicit'), height: 40, width: 100))),
          ])),
        ),
      ));
      await tester.pumpAndSettle();
      expect(activeBackdropFilters(), findsNWidgets(4));
      final geometry = {
        for (final key in ['surface', 'card', 'material', 'explicit'])
          key: tester.getRect(find.byKey(Key(key)))
      };
      await theme.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      expect(theme.frostedGlass, isFalse);
      expect(
          theme.frostedGlassPerformanceMode, FrostedGlassPerformanceMode.off);
      expect(activeBackdropFilters(), findsNothing,
          reason: 'enabled:true 也不能绕过简洁模式');
      for (final key in geometry.keys) {
        expect(tester.getRect(find.byKey(Key(key))), geometry[key]);
      }
      expect(theme.frostedGlassStrength, .65);
      expect(theme.componentOpacity, .43);
      expect(theme.bottomNavAnimationIntensity, .35);
      expect(theme.bottomNavShaderEnabled, isTrue);
      final prefs = await AppPreferencesStore.getInstance();
      expect(prefs.getBool('frosted_glass_enabled'), isTrue);
      expect(prefs.getDouble('frosted_glass_strength'), .65);
      final restored = ThemeProvider(loadOnStart: false);
      addTearDown(restored.dispose);
      await restored.loadThemeForTesting();
      expect(restored.frostedGlass, isFalse);
      expect(restored.frostedGlassStrength, .65);
      await theme.trySetCustomBackgroundMode();
      await tester.pumpAndSettle();
      expect(theme.frostedGlass, isTrue);
      expect(theme.frostedGlassPerformanceMode,
          FrostedGlassPerformanceMode.custom);
      expect(activeBackdropFilters(), findsNWidgets(4));
      expect(theme.componentOpacity, .43);
      expect(tester.takeException(), isNull);
    });
  }

  test('待完成的毛玻璃保存不能在简洁模式重新启用效果', () async {
    final store = _DelayedStore();
    AppPreferencesStore.setCustomInstance(store);
    final theme = ThemeProvider(loadOnStart: false);
    addTearDown(theme.dispose);
    await theme.setBackgroundImage('morenbeijing.jpeg');
    store.gate = Completer<bool>();
    final save = theme.setFrostedGlassStrength(.62);
    await Future<void>.delayed(Duration.zero);
    await theme.setCleanBackgroundMode();
    expect(theme.frostedGlass, isFalse);
    store.gate!.complete(true);
    expect(await save, isTrue);
    expect(theme.frostedGlass, isFalse);
    expect(store.getDouble('frosted_glass_strength'), .62);
    await theme.trySetCustomBackgroundMode();
    expect(theme.frostedGlass, isTrue);
    expect(theme.frostedGlassStrength, .62);
  });
}
