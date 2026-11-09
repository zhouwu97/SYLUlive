import '../../helpers/active_backdrop_filters.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
import 'package:shenliyuan/screens/settings/bottom_navigation_settings_screen.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';
import 'package:shenliyuan/widgets/settings/settings_slider_tile.dart';
import 'package:shenliyuan/widgets/settings/settings_tile.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

Widget _buildTestApp({
  required AuthProvider auth,
  required ThemeProvider theme,
  Brightness brightness = Brightness.light,
  TextScaler systemTextScaler = TextScaler.noScaling,
  TargetPlatform platform = TargetPlatform.android,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<ThemeProvider>.value(value: theme),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        platform: platform,
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final preset = context.watch<ThemeProvider>().fontSizePreset;
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: AppTextScaler(
              systemTextScaler,
              preset.scaleFactor,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AppearanceSettingsScreen(),
    ),
  );
}

Future<Slider> _scrollToSlider(
  WidgetTester tester, {
  required Finder titleFinder,
}) async {
  await tester.scrollUntilVisible(
    titleFinder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  final finder = find.ancestor(
    of: titleFinder,
    matching: find.byType(SettingsSliderTile),
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  return tester.widget<Slider>(
    find.descendant(
      of: finder,
      matching: find.byType(Slider),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuthProvider authProvider;
  late ThemeProvider themeProvider;

  setUp(() async {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(400, 800);
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
    AppPreferencesStore.setMockInitialValues({});
    authProvider = AuthProvider(
      Dio(),
      loadStoredAuth: false,
    );
    themeProvider = ThemeProvider(loadOnStart: false);
    await themeProvider.loadThemeForTesting();
  });

  testWidgets('平板界面设置显示侧边导航入口，旋转及收窄后名称和摘要同步', (tester) async {
    await tester
        .pumpWidget(_buildTestApp(auth: authProvider, theme: themeProvider));
    for (final size in [
      const Size(1280, 800),
      const Size(834, 1194),
      const Size(400, 800)
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      final side = size.width >= 600;
      final entry = find.widgetWithText(SettingsTile, side ? '侧边导航栏' : '底部导航栏');
      await tester.scrollUntilVisible(entry, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(tester.widget<SettingsTile>(entry).subtitle,
          side ? '液态玻璃侧栏 · 高画质' : '液态玻璃底栏 · 高画质');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('界面设置页面正确展示各配置项', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('界面设置'), findsOneWidget);
    expect(find.text('实时预览'), findsOneWidget);
    expect(find.text('简洁模式'), findsOneWidget);
    expect(find.text('自定义背景'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('文字显示'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('文字显示'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('标准 100%'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('交互与视觉效果'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('交互与视觉效果'), findsOneWidget);
    expect(find.text('预测性返回手势'), findsOneWidget);
    expect(find.text('毛玻璃卡片'), findsNothing);
    expect(find.text('毛玻璃特效'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('选择背景图片'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('选择背景图片'), findsOneWidget);

    await _scrollToSlider(
      tester,
      titleFinder: find.text('背景高斯模糊'),
    );

    expect(find.text('背景高斯模糊'), findsOneWidget);
    expect(find.text('组件卡片不透明度'), findsNothing);
    await tester.scrollUntilVisible(find.text('卡片外观'), 140,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('卡片外观'), findsOneWidget);
    // 底栏样式配置（含液态玻璃）已收敛到底部导航栏二级页，外观页只留入口。
    expect(find.text('液态玻璃 2.0 效果'), findsNothing);
    expect(find.text('悬浮式底栏导航'), findsNothing);
  });

  testWidgets('界面设置使用共享壁纸，切回简洁模式保留已选图片', (tester) async {
    await themeProvider.setBackgroundImage('morenbeijing.jpeg');
    await themeProvider.setFrostedGlass(true);
    await tester
        .pumpWidget(_buildTestApp(auth: authProvider, theme: themeProvider));
    await tester.pumpAndSettle();
    expect(find.byType(CustomBackgroundLayer), findsOneWidget);
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent);
    expect(activeBackdropFilters(), findsWidgets);
    await themeProvider.setCleanBackgroundMode();
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        kCleanWarmBackgroundLight);
    expect(themeProvider.backgroundImage, 'morenbeijing.jpeg');
    await themeProvider.trySetCustomBackgroundMode();
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预测性返回开关保留，卡片外观入口集中管理参数和四档开关', (tester) async {
    await themeProvider.setBackgroundImage('morenbeijing.jpeg');
    expect(themeProvider.predictiveBack, isFalse);
    expect(themeProvider.frostedGlass, isFalse);

    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
        platform: TargetPlatform.android,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('预测性返回手势'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('预测性返回手势'), findsOneWidget);
    expect(find.text('毛玻璃卡片'), findsNothing);
    expect(find.text('液态玻璃 2.0 效果'), findsNothing);
    expect(find.text('悬浮式底栏导航'), findsNothing);

    // 点击预测性返回开关
    final predictiveBackTile = find.ancestor(
      of: find.text('预测性返回手势'),
      matching: find.byType(SettingsTile),
    );
    await tester.ensureVisible(predictiveBackTile);
    await tester.pumpAndSettle();

    final predictiveSwitch = find.descendant(
      of: predictiveBackTile,
      matching: find.byType(Switch),
    );
    await tester.tap(predictiveSwitch);
    await tester.pumpAndSettle();

    expect(themeProvider.predictiveBack, isTrue);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getBool('predictive_back_enabled'), isTrue);

    await tester.scrollUntilVisible(find.text('卡片外观'), 140,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('不透明度 100% · 毛玻璃关闭'), findsOneWidget);
    await tester.tap(find.text('卡片外观'));
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
          (widget) => widget is SettingsTile && widget.title == '毛玻璃卡片',
          skipOffstage: false,
        ),
        findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('卡片不透明度'), findsOneWidget);
    await tester.ensureVisible(find.text('高性能'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高性能'));
    await tester.pumpAndSettle();

    expect(themeProvider.frostedGlass, isTrue);
    expect(prefs.getBool('frosted_glass_enabled'), isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('毛玻璃卡片'), findsNothing);
    expect(find.text('不透明度 75% · 高性能'), findsOneWidget);
  });

  testWidgets('卡片外观入口展示预设及不透明度并打开统一设置页', (tester) async {
    await themeProvider.setBackgroundImage('morenbeijing.jpeg');
    await themeProvider.setFrostedGlassPerformanceMode(
        FrostedGlassPerformanceMode.highPerformance);
    await tester
        .pumpWidget(_buildTestApp(auth: authProvider, theme: themeProvider));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('卡片外观'), 200);
    await tester.pumpAndSettle();
    expect(find.text('不透明度 75% · 高性能'), findsOneWidget);
    await tester.tap(find.text('卡片外观'));
    await tester.pumpAndSettle();
    expect(find.text('毛玻璃强度'), findsOneWidget);
    expect(find.text('卡片不透明度'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('不透明度 75% · 高性能'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('字体大小滑块提供六档语义并立即持久化', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    final fontSizeSlider = await _scrollToSlider(
      tester,
      titleFinder: find.text('字体大小'),
    );
    expect(fontSizeSlider.min, 0);
    expect(fontSizeSlider.max, 5);
    expect(fontSizeSlider.divisions, 5);
    expect(fontSizeSlider.value, 2);
    expect(fontSizeSlider.semanticFormatterCallback?.call(0), '较小 90%');
    expect(fontSizeSlider.semanticFormatterCallback?.call(5), '特大 130%');

    final sliderFinder = find.descendant(
      of: find.ancestor(
        of: find.text('字体大小'),
        matching: find.byType(SettingsSliderTile),
      ),
      matching: find.byType(Slider),
    );
    await tester.drag(sliderFinder, const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(themeProvider.fontSizePreset, AppFontSizePreset.extraLarge);
    expect(find.text('特大 130%'), findsOneWidget);
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getString('font_size_preset'), 'extra_large');
  });

  testWidgets('未启用自定义背景时模糊滑块禁用并提示原因', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    // 简洁模式下仍能看到模糊滑块，但处于禁用态
    final blurSlider = await _scrollToSlider(
      tester,
      titleFinder: find.text('背景高斯模糊'),
    );
    expect(blurSlider.onChanged, isNull);
    expect(
      find.text('仅在“自定义背景”模式下生效，请先选择背景图片'),
      findsOneWidget,
    );
  });

  testWidgets('选择自定义背景后模糊滑块启用并切换提示文案', (tester) async {
    await themeProvider.setBackgroundImage(
      'background_test.jpg',
      fillScreen: true,
    );

    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    final blurSlider = await _scrollToSlider(
      tester,
      titleFinder: find.text('背景高斯模糊'),
    );
    expect(blurSlider.onChanged, isNotNull);
    expect(
      find.text('仅模糊自定义背景图片，不影响文字、卡片和按钮'),
      findsOneWidget,
    );
  });

  testWidgets('拖动模糊滑块实时更新 ThemeProvider 并持久化', (tester) async {
    await themeProvider.setBackgroundImage(
      'background_test.jpg',
      fillScreen: true,
    );

    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToSlider(
      tester,
      titleFinder: find.text('背景高斯模糊'),
    );
    final finder = find.ancestor(
      of: find.text('背景高斯模糊'),
      matching: find.byType(SettingsSliderTile),
    );

    await tester.drag(
      find.descendant(
        of: finder,
        matching: find.byType(Slider),
      ),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();

    expect(themeProvider.backgroundBlur, isNot(equals(0)));
    final prefs = await AppPreferencesStore.getInstance();
    expect(prefs.getDouble('background_blur'), themeProvider.backgroundBlur);
  });

  testWidgets('外观页不再保留液态玻璃开关，只留底栏二级页入口', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    // 旧的重复入口已删除，避免与底栏二级页形成双份控制。
    expect(find.widgetWithText(SettingsTile, '液态玻璃 2.0 效果'), findsNothing);
    expect(find.widgetWithText(SettingsTile, '悬浮式底栏导航'), findsNothing);
    // 打开外观页不会改变新版底栏的默认液态效果，控制入口统一在二级页。
    expect(themeProvider.liquidGlass, isTrue);
    expect(themeProvider.bottomNavStyle, BottomNavStyle.liquidGlass);

    // 二级页入口仍然可达。
    await tester.scrollUntilVisible(
      find.widgetWithText(SettingsTile, '底部导航栏'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('底部导航栏'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底栏入口按零强度显示悬浮底栏，其余显示液态玻璃与当前预设', (tester) async {
    await themeProvider
        .setBottomNavPerformanceMode(BottomNavPerformanceMode.off);
    await tester
        .pumpWidget(_buildTestApp(auth: authProvider, theme: themeProvider));
    await tester.pumpAndSettle();
    final entry = find.widgetWithText(SettingsTile, '底部导航栏');
    await tester.scrollUntilVisible(entry, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    String? summary() => tester.widget<SettingsTile>(entry).subtitle;
    expect(summary(), '悬浮底栏');
    await themeProvider.setBottomNavAnimationIntensity(.35);
    await tester.pumpAndSettle();
    expect(summary(), '液态玻璃底栏 · 高性能');
    await themeProvider.setBottomNavAnimationIntensity(1);
    await tester.pumpAndSettle();
    expect(summary(), '液态玻璃底栏 · 高画质');
    await themeProvider.setBottomNavAnimationIntensity(.62);
    await tester.pumpAndSettle();
    expect(summary(), '液态玻璃底栏 · 自定义');
    await themeProvider.setBottomNavAnimationIntensity(0);
    await tester.pumpAndSettle();
    expect(summary(), '悬浮底栏');
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(BottomNavigationSettingsScreen), findsOneWidget);
    final slider = find.descendant(
        of: find.byKey(const ValueKey('bottom-nav-intensity')),
        matching: find.byType(Slider));
    tester.widget<Slider>(slider).onChanged!(.35);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(summary(), '液态玻璃底栏 · 高性能');
    expect(tester.takeException(), isNull);
  });

  final layoutScenarios = [
    (
      name: '浅色标准字号',
      brightness: Brightness.light,
      systemScale: 1.0,
      preset: AppFontSizePreset.standard,
    ),
    (
      name: '深色标准字号',
      brightness: Brightness.dark,
      systemScale: 1.0,
      preset: AppFontSizePreset.standard,
    ),
    (
      name: '系统 1.3 倍字号',
      brightness: Brightness.light,
      systemScale: 1.3,
      preset: AppFontSizePreset.standard,
    ),
    (
      name: '应用 1.3 倍字号',
      brightness: Brightness.light,
      systemScale: 1.0,
      preset: AppFontSizePreset.extraLarge,
    ),
    (
      name: '系统与应用组合 1.69 倍字号',
      brightness: Brightness.light,
      systemScale: 1.3,
      preset: AppFontSizePreset.extraLarge,
    ),
  ];

  for (final scenario in layoutScenarios) {
    testWidgets('${scenario.name}下完整页面无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await themeProvider.setFontSizePreset(scenario.preset);

      await tester.pumpWidget(
        _buildTestApp(
          auth: authProvider,
          theme: themeProvider,
          brightness: scenario.brightness,
          systemTextScaler: TextScaler.linear(scenario.systemScale),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.widgetWithText(SettingsTile, '底部导航栏'),
        280,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('底部导航栏'), findsWidgets);
    });
  }
}
