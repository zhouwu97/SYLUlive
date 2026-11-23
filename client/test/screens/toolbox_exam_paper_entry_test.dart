import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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
