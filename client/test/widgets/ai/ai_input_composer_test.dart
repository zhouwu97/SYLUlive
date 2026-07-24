import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/ai/ai_input_composer.dart';

void main() {
  testWidgets('超过 20 个可见字符时就地提示并禁用发送', (tester) async {
    final controller = TextEditingController(text: List.filled(21, '一').join());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiInputComposer(
            hintText: 'Enter prompt...',
            controller: controller,
            maxCharacters: 20,
            enabled: true,
            running: false,
            onSend: (_) => fail('超长消息不应发送'),
          ),
        ),
      ),
    );

    expect(find.text('最多输入 20 个可见字符'), findsOneWidget);
    expect(find.text('21/20'), findsOneWidget);
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
  });
}
