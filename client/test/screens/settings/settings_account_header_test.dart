import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/settings/settings_account_header.dart';

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider(this._testUser)
      : super(Dio(), loadStoredAuth: false, onAuthenticated: () {});

  final User? _testUser;

  @override
  User? get user => _testUser;

  @override
  bool get isLoggedIn => _testUser != null;
}

Widget _buildHeader(User? user) {
  return ChangeNotifierProvider<AuthProvider>.value(
    value: _TestAuthProvider(user),
    child: const MaterialApp(
      home: Scaffold(body: SettingsAccountHeader()),
    ),
  );
}

User _user({String loginAccount = '', int id = 1}) {
  return User(
    id: id,
    studentId: '',
    loginAccount: loginAccount,
    nickname: '邮箱用户',
    createdAt: DateTime(2026, 8, 23),
  );
}

void main() {
  testWidgets('展示 App 账号与未绑定专业保护', (tester) async {
    await tester.pumpWidget(_buildHeader(_user(loginAccount: 'user@example.com')));

    expect(find.text('App 账号：user@example.com'), findsOneWidget);
    expect(find.text('计算机科学与技术'), findsNothing);
  });

  testWidgets('未提供 loginAccount 时降级展示 App ID', (tester) async {
    await tester.pumpWidget(_buildHeader(_user(id: 7, loginAccount: '')));

    expect(find.text('App ID 7'), findsOneWidget);
    expect(find.text('计算机科学与技术'), findsNothing);
  });

  testWidgets('未登录时展示未登录引导', (tester) async {
    await tester.pumpWidget(_buildHeader(null));

    expect(find.text('登录沈理校园'), findsOneWidget);
    expect(find.text('登录后管理账号和教务数据'), findsOneWidget);
  });
}
