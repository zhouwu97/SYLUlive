import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
import 'package:shenliyuan/theme/app_text_scaler.dart';
import 'package:shenliyuan/widgets/settings/settings_slider_tile.dart';
import 'package:shenliyuan/widgets/settings/settings_tile.dart';

Widget _buildTestApp({
  required AuthProvider auth,
  required ThemeProvider theme,
  Brightness brightness = Brightness.light,
  TextScaler systemTextScaler = TextScaler.noScaling,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<ThemeProvider>.value(value: theme),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
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
    AppPreferencesStore.setMockInitialValues({});
    authProvider = AuthProvider(
      Dio(),
      loadStoredAuth: false,
    );
    themeProvider = ThemeProvider(loadOnStart: false);
    await themeProvider.loadThemeForTesting();
  });

  testWidgets('外观与显示页面正确展示各配置项', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外观与显示'), findsOneWidget);
    expect(find.text('实时预览'), findsOneWidget);
    expect(find.text('简洁模式'), findsOneWidget);
    expect(find.text('自定义背景'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(find.text('文字显示'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('标准 100%'), findsOneWidget);

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
    expect(find.text('组件卡片不透明度'), findsOneWidget);
    // 底栏样式配置（含液态玻璃）已收敛到底部导航栏二级页，外观页只留入口。
    expect(find.text('液态玻璃 2.0 效果'), findsNothing);
    expect(find.text('悬浮式底栏导航'), findsNothing);
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
    // 液态玻璃状态只能经底栏二级页修改（那里有 GPU 确认弹窗）。
    expect(themeProvider.liquidGlass, isFalse);
    expect(themeProvider.bottomNavStyle, BottomNavStyle.floating);

    // 二级页入口仍然可达。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('底部导航栏'), findsWidgets);
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
