import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/widgets/required_legal_consent_dialog.dart';

void main() {
  testWidgets('协议确认需要勾选全部必选授权后才能继续', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => AuthProvider(
          Dio(),
          loadStoredAuth: false,
          onAuthenticated: () {},
        ),
        child: const MaterialApp(
          home: RequiredLegalConsentDialog(requiresEduDataConsent: true),
        ),
      ),
    );

    final confirm = find.byKey(const ValueKey('required-consent-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('required-general-consents')),
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('required-edu-consent')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
  });
}
