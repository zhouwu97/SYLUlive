import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/controllers/post_reply_composer_controller.dart';
import 'package:shenliyuan/widgets/post_reply_composer.dart';

void main() {
  testWidgets('keyboard metrics: 320 -> 280 -> 235 -> 190 -> 145 -> 105 -> 0 过程中 stableKeyboardHeight 保持 320', (tester) async {
    final controller = PostReplyComposerController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostReplyComposer(
            controller: controller,
            sending: false,
            enabled: true,
            onSubmit: (_) async => true,
            onNeedLogin: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 模拟软键盘完全弹出至 320
    controller.updateKeyboardMetrics(320);
    expect(controller.stableKeyboardHeight, 320);

    // 2. 模拟软键盘收起过程中的逐帧递减
    final collapsingFrames = [280.0, 235.0, 190.0, 145.0, 105.0, 0.0];
    for (final inset in collapsingFrames) {
      controller.updateKeyboardMetrics(inset);
      // 关键断言：无论收起阶段过渡帧是多少，稳定键盘高度不能被踩坏成递减的值，恒定为 320
      expect(controller.stableKeyboardHeight, 320);
    }
  });
}
