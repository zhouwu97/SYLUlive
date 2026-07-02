import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/search_focus_gate.dart';

void main() {
  test('focused search input consumes post tap and requests unfocus', () {
    var unfocusCalls = 0;

    final consumed = consumeSearchInputExit(
      hasFocus: true,
      unfocus: () => unfocusCalls++,
    );

    expect(consumed, isTrue);
    expect(unfocusCalls, 1);
  });

  test('unfocused search input lets post tap continue', () {
    var unfocusCalls = 0;

    final consumed = consumeSearchInputExit(
      hasFocus: false,
      unfocus: () => unfocusCalls++,
    );

    expect(consumed, isFalse);
    expect(unfocusCalls, 0);
  });
}
