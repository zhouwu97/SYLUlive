import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/settings_screen.dart';

Widget _buildTestApp({
  required AuthProvider auth,
  required ThemeProvider theme,
  required EduProvider edu,
  required CourseScheduleProvider course,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<ThemeProvider>.value(value: theme),
      ChangeNotifierProvider<EduProvider>.value(value: edu),
      ChangeNotifierProvider<CourseScheduleProvider>.value(value: course),
    ],
    child: const MaterialApp(
      home: SettingsScreen(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuthProvider authProvider;
  late ThemeProvider themeProvider;
  late EduProvider eduProvider;
  late CourseScheduleProvider courseProvider;

  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    authProvider = AuthProvider(
      Dio(),
      loadStoredAuth: false,
    );
    themeProvider = ThemeProvider(loadOnStart: false);
    await themeProvider.loadThemeForTesting();
    final dio = Dio();
    eduProvider = EduProvider(dio);
    courseProvider = CourseScheduleProvider(dio);
  });

  testWidgets('主设置页展示 6 个主要入口，不直接展示修改密码与保活开关', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
        edu: eduProvider,
        course: courseProvider,
      ),
    );
    await tester.pumpAndSettle();

    // 6 个一级入口
    expect(find.text('外观与显示'), findsOneWidget);
    expect(find.text('通知与后台'), findsOneWidget);
    expect(find.text('账号与安全'), findsOneWidget);
    expect(find.text('隐私与数据'), findsOneWidget);
    expect(find.text('诊断与反馈'), findsOneWidget);
    expect(find.text('关于沈理校园'), findsOneWidget);

    // 首页不直接平铺过往重复入口
    expect(find.text('选择背景图片'), findsNothing);
    expect(find.text('修改密码'), findsNothing);
    expect(find.text('极光推送'), findsNothing);
  });

  testWidgets('未登录状态下显示登录引导，不显示退出登录按钮', (tester) async {
    await tester.pumpWidget(
      _buildTestApp(
        auth: authProvider,
        theme: themeProvider,
        edu: eduProvider,
        course: courseProvider,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录沈理校园'), findsOneWidget);
    expect(find.text('登录后管理账号和教务数据'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
  });
}
