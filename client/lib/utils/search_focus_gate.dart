import 'package:flutter/foundation.dart';

bool consumeSearchInputExit({
  required bool hasFocus,
  required VoidCallback unfocus,
}) {
  if (!hasFocus) return false;
  unfocus();
  return true;
}
