import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/bottom_navigation_settings_screen.dart';

Widget _buildApp(ThemeProvider themeProvider) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: themeProvider,
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: const BottomNavigationSettingsScreen(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider themeProvider;

  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    themeProvider = ThemeProvider(
      loadOnStart: false,
      performanceLevel: DevicePerformanceLevel.high,
    );
    await themeProvider.loadThemeForTesting();
  });

  tearDown(() => themeProvider.dispose());

  testWidgets('展示三种底栏样式与设备性能策略', (tester) async {
    await tester.pumpWidget(_buildApp(themeProvider));
    await tester.pumpAndSettle();

    expect(find.text('底部导航栏'), findsOneWidget);
    expect(find.text('预览区域'), findsOneWidget);
    expect(find.text('标准底栏'), findsOneWidget);
    expect(find.text('悬浮底栏'), findsOneWidget);
    expect(find.text('液态玻璃底栏'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('高性能'), findsOneWidget);
    expect(find.text('高画质'), findsOneWidget);
    expect(themeProvider.bottomNavStyle, BottomNavStyle.floating);
  });

  testWidgets('首次开启液态玻璃先确认，确认后保存新配置', (tester) async {
    await tester.pumpWidget(_buildApp(themeProvider));
    await tester.pumpAndSettle();

    await tester.tap(find.text('液态玻璃底栏'));
    await tester.pumpAndSettle();
    expect(find.text('启用液态玻璃底栏？'), findsOneWidget);
    expect(find.text('液态玻璃会增加 GPU 负载，部分设备可能降低续航或帧率。'), findsOneWidget);
    expect(themeProvider.bottomNavStyle, BottomNavStyle.floating);

    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();

    expect(themeProvider.bottomNavStyle, BottomNavStyle.liquidGlass);
    expect(themeProvider.bottomNavLiquidGlassConfirmed, isTrue);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('bottom_nav_style'), 'liquid_glass');
    expect(prefs.getBool('floating_nav'), isTrue);
    expect(prefs.getBool('liquid_glass'), isTrue);
  });

  testWidgets('动画强度与性能模式会持久化', (tester) async {
    await tester.pumpWidget(_buildApp(themeProvider));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高性能'));
    await tester.pumpAndSettle();
    expect(
      themeProvider.bottomNavPerformanceMode,
      BottomNavPerformanceMode.highPerformance,
    );

    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(themeProvider.bottomNavAnimationIntensity, lessThan(0.65));
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('bottom_nav_performance_mode'), 'high_performance');
    expect(prefs.getDouble('bottom_nav_animation_intensity'),
        themeProvider.bottomNavAnimationIntensity);
  });

  testWidgets('暗色与大字号预览不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          textScaler: TextScaler.linear(1.3),
        ),
        child: Theme(
          data: ThemeData.dark(useMaterial3: true),
          child: _buildApp(themeProvider),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('高画质'), findsOneWidget);
  });
}
