import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/personal_ai_runtime_limits.dart';

void main() {
  test('个人输入接受 8000 个可见字符并拒绝 8001 个', () {
    final accepted = List<String>.filled(8000, 'x').join();
    final rejected = List<String>.filled(8001, 'x').join();
    expect(
      PersonalAIRuntimeLimits.acceptsInput(accepted),
      isTrue,
    );
    expect(
      PersonalAIRuntimeLimits.acceptsInput(rejected),
      isFalse,
    );
  });

  test('个人输入按可见字符而不是 UTF-16 单元计数', () {
    expect(PersonalAIRuntimeLimits.inputCharacters('👨‍👩‍👧‍👦'), 1);
  });
}
