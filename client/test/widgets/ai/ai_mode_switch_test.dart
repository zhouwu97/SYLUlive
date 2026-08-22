import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/ai/ai_mode_switch.dart';

void main() {
  testWidgets('AiModeSwitch toggles modes correctly', (tester) async {
    bool isPersonalMode = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return AiModeSwitch(
                isPersonalMode: isPersonalMode,
                onModeChanged: (selected) {
                  setState(() {
                    isPersonalMode = selected;
                  });
                },
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('校园 Agent'), findsOneWidget);
    expect(find.text('个人助手'), findsOneWidget);

    await tester.tap(find.text('个人助手'));
    await tester.pumpAndSettle();

    expect(isPersonalMode, isTrue);

    await tester.tap(find.text('校园 Agent'));
    await tester.pumpAndSettle();

    expect(isPersonalMode, isFalse);
  });
}
