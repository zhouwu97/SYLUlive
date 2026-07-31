import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/ai/ai_input_composer.dart';

void main() {
  testWidgets('500 个可见字符允许发送，501 个时就地提示并禁用', (tester) async {
    final controller =
        TextEditingController(text: List.filled(500, '一').join());
    addTearDown(controller.dispose);
    var submitted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiInputComposer(
            hintText: 'Enter prompt...',
            controller: controller,
            maxCharacters: 500,
            enabled: true,
            running: false,
            onSend: (_) => submitted = true,
          ),
        ),
      ),
    );

    expect(find.text('500/500'), findsOneWidget);
    expect(find.text('最多输入 500 个可见字符'), findsNothing);
    await tester.tap(find.byType(IconButton));
    expect(submitted, isTrue);

    controller.text = List.filled(501, '一').join();
    await tester.pump();

    expect(find.text('最多输入 500 个可见字符'), findsOneWidget);
    expect(find.text('501/500'), findsOneWidget);
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
  });
}
