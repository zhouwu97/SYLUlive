import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/login_screen.dart';

void main() {
  testWidgets('注册协议合并确认并按注册身份展示教务授权', (tester) async {
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

    final generalConsent =
        find.byKey(const ValueKey('registration-general-consents'));
    final eduConsent = find.byKey(const ValueKey('registration-edu-consent'));

    expect(generalConsent, findsOneWidget);
    expect(eduConsent, findsOneWidget);
    expect(find.text('我已阅读并同意《用户协议》'), findsNothing);
    expect(find.text('含用户协议、隐私政策等 6 项'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('registration-general-consents-details')),
    );
    await tester.pumpAndSettle();
    expect(find.text('协议与隐私政策'), findsOneWidget);
    expect(find.text('用户协议'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.ensureVisible(generalConsent);
    await tester.tap(generalConsent);
    await tester.pump();
    expect(tester.widget<Checkbox>(generalConsent).value, isTrue);

    await tester.ensureVisible(find.text('毕业人员注册'));
    await tester.tap(find.text('毕业人员注册'));
    await tester.pumpAndSettle();

    expect(generalConsent, findsOneWidget);
    expect(tester.widget<Checkbox>(generalConsent).value, isTrue);
    expect(eduConsent, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
