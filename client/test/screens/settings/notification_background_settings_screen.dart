import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/notification_background_settings_screen.dart';

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
      home: NotificationBackgroundSettingsScreen(),
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

  testWidgets('通知与后台页面展示状态概览与本地提醒说明', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('通知与后台'), findsOneWidget);
    expect(find.text('状态概览'), findsOneWidget);
    expect(find.text('远程消息推送'), findsOneWidget);
    expect(find.text('后台保活服务'), findsOneWidget);
    expect(find.text('课程与考试提醒说明'), findsOneWidget);
    expect(find.text('后台保活'), findsOneWidget);
  });
}
