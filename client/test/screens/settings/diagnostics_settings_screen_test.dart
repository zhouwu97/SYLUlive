import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings/diagnostics_settings_screen.dart';

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
      home: DiagnosticsSettingsScreen(),
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

  testWidgets('诊断与反馈页面正常渲染结论与反馈入口', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('诊断与反馈'), findsOneWidget);
    expect(find.text('运行诊断日志'), findsOneWidget);
    expect(find.text('问题与建议反馈'), findsOneWidget);
  });
}
