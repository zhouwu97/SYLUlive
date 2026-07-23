import 'package:characters/characters.dart';

abstract final class PersonalAIRuntimeLimits {
  static const int maximumInputCharacters = 8000;

  static int inputCharacters(String value) => value.trim().characters.length;

  static bool acceptsInput(String value) {
    final length = inputCharacters(value);
    return length > 0 && length <= maximumInputCharacters;
  }
}
