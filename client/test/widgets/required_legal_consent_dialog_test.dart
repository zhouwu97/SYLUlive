import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/required_legal_consent_dialog.dart';

void main() {
  testWidgets('教务用户必须确认通用协议和教务专项授权', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RequiredLegalConsentDialog(requiresEduDataConsent: true),
      ),
    );

    final confirm = find.byKey(const ValueKey('required-consent-confirm'));
    expect(confirm, findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('required-general-consents')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('required-edu-consent')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
  });
}
