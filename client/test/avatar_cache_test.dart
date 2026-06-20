import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/cached_avatar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AvatarCache reuses provider for the same url and size', () {
    final first = AvatarCache.provider(
      'https://example.com/avatar.png',
      radius: 20,
    );
    final second = AvatarCache.provider(
      'https://example.com/avatar.png',
      radius: 20,
    );

    expect(identical(first, second), isTrue);
  });
}
