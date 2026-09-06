import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/login_screen.dart';

void main() {
  testWidgets('登录账号框允许输入完整邮箱', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(
          Dio(),
          loadStoredAuth: false,
          onAuthenticated: () {},
        ),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    final accountField = tester.widget<TextField>(
      find.byType(TextField).first,
    );
    expect(accountField.maxLength, 254);
    expect(accountField.keyboardType, TextInputType.emailAddress);
  });

  testWidgets('邮箱注册只需要基础协议，不展示教务授权', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(
          Dio(),
          loadStoredAuth: false,
          onAuthenticated: () {},
        ),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    await tester.tap(find.text('没有账号？去注册'));
    await tester.pumpAndSettle();

    final agreement = find.byKey(const ValueKey('registration-user-agreement'));
    final privacy = find.byKey(const ValueKey('registration-privacy-policy'));

    expect(find.byKey(const ValueKey('registration-consent-panel')),
        findsOneWidget);
    expect(agreement, findsOneWidget);
    expect(privacy, findsOneWidget);
    expect(
        find.byKey(const ValueKey('registration-edu-consent')), findsNothing);
    expect(find.textContaining('6 项'), findsNothing);

    await tester.ensureVisible(agreement);
    await tester.tap(agreement);
    await tester.ensureVisible(privacy);
    await tester.tap(privacy);
    await tester.pump();
    expect(tester.widget<Checkbox>(agreement).value, isTrue);
    expect(tester.widget<Checkbox>(privacy).value, isTrue);

    expect(agreement, findsOneWidget);
    expect(privacy, findsOneWidget);
    expect(tester.widget<Checkbox>(agreement).value, isTrue);
    expect(tester.widget<Checkbox>(privacy).value, isTrue);
    expect(find.text('毕业人员注册'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
