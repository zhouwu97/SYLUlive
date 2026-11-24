import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/physical_test_screen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/toolbox_screen.dart';

class _Auth extends AuthProvider {
  _Auth(this.fixtureUser) : super(Dio(), loadStoredAuth: false);
  final User fixtureUser;
  @override
  bool get isLoggedIn => true;
  @override
  User get user => fixtureUser;
}

void main() {
  for (final saved in [true, false]) {
    testWidgets('体测保存密码后自动打开查询，未保存时等待输入：saved=$saved', (tester) async {
      AppPreferencesStore.setMockInitialValues({});
      const password = '@Fixture0+&=%•';
      FlutterSecureStorage.setMockInitialValues({
        if (saved) 'secure_physical_test_pwd_20260001': password,
      });
      await tester.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false)),
        ChangeNotifierProvider<AuthProvider>(
            create: (_) => _Auth(User(
                id: 1,
                studentId: '20260001',
                nickname: '测试',
                createdAt: DateTime(2026)))),
      ], child: const MaterialApp(home: ToolboxScreen())));
      await tester.tap(find.text('体测成绩'));
      await tester.pumpAndSettle();
      if (saved) {
        expect(
            tester
                .widget<PhysicalTestPage>(find.byType(PhysicalTestPage))
                .password,
            password);
        await tester.tap(find.text('返回修改密码'));
        await tester.pumpAndSettle();
        expect(find.byType(PhysicalTestPage), findsNothing);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, password);
        expect(field.obscureText, isTrue);
        await tester.enterText(find.byType(TextField), '${password}new');
        await tester.tap(find.text('开始查询'));
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<PhysicalTestPage>(find.byType(PhysicalTestPage))
                .password,
            '${password}new');
      } else {
        expect(find.byType(PhysicalTestPage), findsNothing);
        expect(find.text('开始查询'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (label, verified, role, visible) in [
    ('未配置账号可从试卷库进入配置引导', false, 'user', true),
    ('完成教务认证后显示试卷库入口', true, 'user', true),
    ('管理员未认证也显示试卷库入口', false, 'admin', true),
  ]) {
    testWidgets(label, (tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(loadOnStart: false),
            ),
            ChangeNotifierProvider<AuthProvider>(
              create: (_) => _Auth(User(
                id: 1,
                studentId: '20260001',
                nickname: '测试',
                role: role,
                academicConfigured: verified,
                createdAt: DateTime(2026),
              )),
            ),
          ],
          child: const MaterialApp(home: ToolboxScreen()),
        ),
      );

      expect(find.text('试卷库'), visible ? findsOneWidget : findsNothing);
    });
  }
}
