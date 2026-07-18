import 'package:flutter/widgets.dart';

/// 将文本插入当前选区，并把光标移动到插入内容之后。
void insertAtSelection(TextEditingController controller, String value) {
  if (value.isEmpty) return;
  final text = controller.text;
  final selection = controller.selection;
  final start = _clampOffset(
    selection.isValid ? selection.start : text.length,
    text.length,
  );
  final end = _clampOffset(
    selection.isValid ? selection.end : text.length,
    text.length,
  );
  final selectionStart = start <= end ? start : end;
  final selectionEnd = start <= end ? end : start;
  final updated = text.replaceRange(selectionStart, selectionEnd, value);
  final cursor = selectionStart + value.length;
  controller.value = controller.value.copyWith(
    text: updated,
    selection: TextSelection.collapsed(offset: cursor),
    composing: TextRange.empty,
  );
}

/// 删除光标前一个用户可见字符，避免破坏组合 Emoji。
void deletePreviousCharacter(TextEditingController controller) {
  final text = controller.text;
  final selection = controller.selection;
  if (!selection.isValid) return;

  final start = _clampOffset(selection.start, text.length);
  final end = _clampOffset(selection.end, text.length);
  if (start != end) {
    final selectionStart = start < end ? start : end;
    final updated =
        text.replaceRange(selectionStart, start > end ? start : end, '');
    controller.value = controller.value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: selectionStart),
      composing: TextRange.empty,
    );
    return;
  }

  if (start == 0) return;
  var clusterStart = 0;
  var clusterEnd = 0;
  var offset = 0;
  final Characters graphemes = text.characters;
  for (final cluster in graphemes) {
    final nextOffset = offset + cluster.length;
    if (start <= nextOffset) {
      clusterStart = offset;
      clusterEnd = nextOffset;
      break;
    }
    offset = nextOffset;
  }
  if (clusterEnd == 0) {
    final previous = text.substring(0, start).characters.last;
    clusterStart = start - previous.length;
    clusterEnd = start;
  }
  final updated = text.replaceRange(clusterStart, clusterEnd, '');
  controller.value = controller.value.copyWith(
    text: updated,
    selection: TextSelection.collapsed(offset: clusterStart),
    composing: TextRange.empty,
  );
}

int _clampOffset(int offset, int length) {
  if (offset < 0) return 0;
  if (offset > length) return length;
  return offset;
}
