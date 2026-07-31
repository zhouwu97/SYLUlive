import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
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
    expect(find.text('夜间模式'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(find.text('组件不透明度'), findsOneWidget);
    expect(find.text('液态玻璃效果'), findsOneWidget);
    expect(find.text('悬浮底部导航栏'), findsWidgets);
    expect(find.text('预测性返回手势'), findsOneWidget);
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

    final glassTile = find.widgetWithText(SettingsTile, '液态玻璃效果');
    final glassSwitch = find.descendant(
      of: glassTile,
      matching: find.byType(Switch),
    );

    await tester.tap(glassSwitch);
    await tester.pumpAndSettle();

    // 确认弹窗
    expect(find.text('液态玻璃效果可能增加 GPU 负担，部分设备可能出现掉帧或发热。'), findsOneWidget);

    // 点击取消
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(themeProvider.liquidGlass, isFalse);

    // 再次点击并确认开启
    await tester.tap(glassSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然开启'));
    await tester.pumpAndSettle();
    expect(themeProvider.liquidGlass, isTrue);
  });
}
