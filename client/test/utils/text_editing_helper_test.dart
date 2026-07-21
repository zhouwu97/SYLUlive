import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import '../../lib/utils/text_editing_helper.dart';

void main() {
  group('text editing helper', () {
    test('inserts at the current cursor position', () {
      final controller = TextEditingController(text: 'ab');
      controller.selection = const TextSelection.collapsed(offset: 1);

      insertAtSelection(controller, '😀');

      expect(controller.text, 'a😀b');
      expect(controller.selection.baseOffset, 'a😀'.length);
    });

    test('replaces selected text', () {
      final controller = TextEditingController(text: 'hello');
      controller.selection =
          const TextSelection(baseOffset: 1, extentOffset: 4);

      insertAtSelection(controller, '❤️');

      expect(controller.text, 'h❤️o');
    });

    test('deletes one complete visible Emoji cluster', () {
      for (final value in ['👨‍👩‍👧‍👦', '🇨🇳', '👍🏻', '❤️']) {
        final controller = TextEditingController(text: 'A$value');
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);

        deletePreviousCharacter(controller);

        expect(controller.text, 'A', reason: 'failed for $value');
      }
    });

    test('deletes a selected range before handling clusters', () {
      final controller = TextEditingController(text: 'A😀B');
      controller.selection =
          const TextSelection(baseOffset: 1, extentOffset: 3);

      deletePreviousCharacter(controller);

      expect(controller.text, 'AB');
      expect(controller.selection.baseOffset, 1);
    });
  });
}
