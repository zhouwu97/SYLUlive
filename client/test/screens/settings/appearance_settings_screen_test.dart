import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
import 'package:shenliyuan/widgets/settings/settings_slider_tile.dart';
import 'package:shenliyuan/widgets/settings/settings_tile.dart';

Widget _buildTestApp({
  required AuthProvider auth,
  required ThemeProvider theme,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<ThemeProvider>.value(value: theme),
    ],
    child: const MaterialApp(
      home: AppearanceSettingsScreen(),
    ),
  );
}

Future<Slider> _scrollToSlider(
  WidgetTester tester, {
  required Finder titleFinder,
}) async {
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
    expect(find.text('选择背景图片'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(find.text('背景高斯模糊'), findsOneWidget);
    expect(find.text('组件卡片不透明度'), findsOneWidget);
    expect(find.text('液态玻璃 2.0 效果'), findsOneWidget);
    expect(find.text('悬浮式底栏导航'), findsOneWidget);
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

    final finder = find.ancestor(
      of: find.text('背景高斯模糊'),
      matching: find.byType(SettingsSliderTile),
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();

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

  testWidgets('开启液态玻璃效果弹窗确认', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    expect(themeProvider.liquidGlass, isFalse);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();

    final glassTile = find.widgetWithText(SettingsTile, '液态玻璃 2.0 效果');
    final glassSwitch = find.descendant(
      of: glassTile,
      matching: find.byType(Switch),
    );

    await tester.tap(glassSwitch);
    await tester.pumpAndSettle();

    // 确认弹窗
    expect(
      find.text(
        '液态玻璃效果使用高阶层叠加与高斯模糊渲染。在部分低配置设备上可能增加渲染开销，确定要开启吗？',
      ),
      findsOneWidget,
    );

    // 点击取消
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(themeProvider.liquidGlass, isFalse);

    // 再次点击并确认开启
    await tester.tap(glassSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(themeProvider.liquidGlass, isTrue);
  });
}
