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

User _user({String eduCollege = '', String eduMajor = ''}) {
  return User(
    id: 1,
    studentId: '',
    nickname: '邮箱用户',
    createdAt: DateTime(2026, 8, 23),
    eduCollege: eduCollege,
    eduMajor: eduMajor,
  );
}

void main() {
  testWidgets('未教务认证账户不显示伪造的默认专业', (tester) async {
    await tester.pumpWidget(_buildHeader(_user()));

    expect(find.text('学号已保密 · 未绑定教务'), findsOneWidget);
    expect(find.text('计算机科学与技术'), findsNothing);
  });

  testWidgets('已有教务专业时继续显示真实专业', (tester) async {
    await tester.pumpWidget(_buildHeader(_user(eduMajor: '软件工程')));

    expect(find.text('学号已保密 · 软件工程'), findsOneWidget);
    expect(find.text('计算机科学与技术'), findsNothing);
  });

  testWidgets('只有学院资料时显示学院而不是默认专业', (tester) async {
    await tester.pumpWidget(_buildHeader(_user(eduCollege: '信息科学与工程学院')));

    expect(find.text('学号已保密 · 信息科学与工程学院'), findsOneWidget);
    expect(find.text('计算机科学与技术'), findsNothing);
  });
}
