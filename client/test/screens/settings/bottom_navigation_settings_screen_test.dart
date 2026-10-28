import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/bottom_navigation_settings_screen.dart';
import 'package:shenliyuan/widgets/liquid_bottom_nav.dart';

Widget app(ThemeProvider theme) => ChangeNotifierProvider.value(
    value: theme,
    child: const MaterialApp(home: BottomNavigationSettingsScreen()));

void main() {
  testWidgets('正式清透开关更新预览并持久化，不被画质模式覆盖', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final provider = ThemeProvider(loadOnStart: false);
    addTearDown(provider.dispose);
    await tester.pumpWidget(app(provider));
    await tester.pumpAndSettle();
    expect(provider.bottomNavClearMaterial, isFalse);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-clear-material')));
    await tester.pumpAndSettle();
    expect(provider.bottomNavClearMaterial, isTrue);
    final preview = tester.widget<LiquidBottomNav>(find.byType(LiquidBottomNav));
    expect(preview.blur, 0);
    expect(preview.tint, .06);
    await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.highPerformance);
    await provider.loadThemeForTesting();
    expect(provider.bottomNavClearMaterial, isTrue);
    expect(provider.bottomNavShaderEnabled, isTrue);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom-nav-clear-material')));
    await tester.pumpAndSettle();
    await provider.loadThemeForTesting();
    expect(provider.bottomNavClearMaterial, isFalse);
    expect(provider.bottomNavBlur, 6);
    expect(provider.bottomNavTint, isNull);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late ThemeProvider theme;
  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    theme = ThemeProvider(
        loadOnStart: false, performanceLevel: DevicePerformanceLevel.high);
    await theme.loadThemeForTesting();
  });
  tearDown(() => theme.dispose());

  testWidgets('新底栏默认完整画质，设置页不再提供旧样式', (tester) async {
    await tester.pumpWidget(app(theme));
    await tester.pumpAndSettle();
    expect(find.text('底部导航栏'), findsOneWidget);
    expect(find.byType(LiquidBottomNav), findsOneWidget);
    expect(find.text('标准底栏'), findsNothing);
    expect(find.text('悬浮底栏'), findsNothing);
    expect(find.byType(RadioGroup<BottomNavStyle>), findsNothing);
    expect(theme.bottomNavShaderEnabled, isTrue);
    expect(theme.bottomNavAnimationIntensity, 1);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-item-4')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<LiquidBottomNav>(find.byType(LiquidBottomNav))
            .currentIndex,
        4);
    expect(tester.takeException(), isNull);
  });

  test('旧用户普通底栏、关闭玻璃、低强度偏好统一迁移，新偏好可持久化', () async {
    AppPreferencesStore.setMockInitialValues({
      'bottom_nav_style': 'normal',
      'floating_nav': false,
      'liquid_glass': false,
      'bottom_nav_performance_mode': 'high_performance',
      'bottom_nav_animation_intensity': 0.0,
    });
    await theme.loadThemeForTesting();
    expect(theme.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(theme.floatingNavBar, isTrue);
    expect(theme.bottomNavShaderEnabled, isTrue);
    expect(theme.bottomNavAnimationIntensity, 1);
    await theme
        .setBottomNavPerformanceMode(BottomNavPerformanceMode.highPerformance);
    await theme.setBottomNavAnimationIntensity(.4);
    await theme.loadThemeForTesting();
    expect(theme.bottomNavShaderEnabled, isTrue);
    expect(theme.bottomNavAnimationIntensity, .4);
    await theme.setBottomNavStyle(BottomNavStyle.normal);
    expect(theme.bottomNavStyle, BottomNavStyle.liquidGlass);
  });

  testWidgets('动画强度与性能模式交互会持久化', (tester) async {
    await tester.pumpWidget(app(theme));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('高性能'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高性能'));
    await tester.pumpAndSettle();
    expect(theme.bottomNavShaderEnabled, isTrue);
    expect(theme.bottomNavAnimationIntensity, .35);
    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(theme.bottomNavAnimationIntensity, lessThan(1));
    final prefs = await AppPreferencesStore.getInstance();
    expect(
        prefs.getString('bottom_nav_performance_mode_v2'), 'high_performance');
    expect(prefs.getDouble('bottom_nav_animation_intensity_v2'),
        theme.bottomNavAnimationIntensity);
    await tester.ensureVisible(find.text('高画质'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高画质'));
    await tester.pumpAndSettle();
    expect(theme.bottomNavAnimationIntensity, 1);
    expect(theme.bottomNavShaderEnabled, isTrue);
    await theme.loadThemeForTesting();
    expect(theme.bottomNavAnimationIntensity, 1);
  });

  test('自动档按设备调整运动，但每一档都保留折射', () async {
    for (final level in DevicePerformanceLevel.values) {
      final provider =
          ThemeProvider(loadOnStart: false, performanceLevel: level);
      await provider.setBottomNavPerformanceMode(BottomNavPerformanceMode.auto);
      expect(provider.bottomNavShaderEnabled, isTrue);
      expect(
          provider.bottomNavAnimationIntensity,
          level == DevicePerformanceLevel.low
              ? .35
              : level == DevicePerformanceLevel.medium
                  ? .65
                  : 1);
      provider.dispose();
    }
  });

  testWidgets('窄屏设置预览和选项不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(theme));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Liquid Glass Reference QA'), 200);
    expect(tester.takeException(), isNull);
  });
}
