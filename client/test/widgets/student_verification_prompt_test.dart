import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/student_verification_prompt.dart';

class _Auth extends AuthProvider {
  _Auth(this.fixtureUser) : super(Dio(), loadStoredAuth: false);
  final User fixtureUser;
  @override
  bool get isLoggedIn => true;
  @override
  User get user => fixtureUser;
  @override
  Future<void> refreshUser() async {}
}

void main() {
  setUp(() => AppPreferencesStore.setCustomInstance(MemoryPreferencesStore()));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  Future<void> trigger(WidgetTester tester, User user) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => _Auth(user),
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => StudentVerificationPrompt.maybeShow(context),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
  }

  User account({bool verified = false, String role = 'user', bool consent = true}) =>
      User(
        id: 7,
        studentId: '20260001',
        nickname: '测试',
        role: role,
        studentVerified: verified,
        legalConsentsActive: consent,
        createdAt: DateTime(2026),
      );

  testWidgets('未认证账号只弹一次，取消后不再弹', (tester) async {
    await trigger(tester, account());
    expect(find.text('完成学生认证'), findsOneWidget);
    await tester.tap(find.text('暂不认证'));
    await tester.pumpAndSettle();
    expect(find.text('完成学生认证'), findsNothing);

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
    expect(find.text('完成学生认证'), findsNothing);
  });

  for (final (label, user) in [
    ('已认证账号不弹', account(verified: true)),
    ('管理员不弹', account(role: 'admin')),
    ('协议未确认时不弹，避免叠在协议弹窗上', account(consent: false)),
  ]) {
    testWidgets(label, (tester) async {
      await trigger(tester, user);
      expect(find.text('完成学生认证'), findsNothing);
    });
  }
}
