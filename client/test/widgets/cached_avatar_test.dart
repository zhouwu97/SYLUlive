import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/cached_avatar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (_) async {
      return Directory.systemTemp.path;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  test('全局头像缓存按显示尺寸复用缩略图 provider', () {
    const avatarUrl = 'https://example.com/avatar-cache-test.png';

    final compact = AvatarCache.provider(avatarUrl, radius: 17);
    final compactAgain = AvatarCache.provider(avatarUrl, radius: 17);
    final large = AvatarCache.provider(avatarUrl, radius: 24);
    final dense = AvatarCache.provider(
      avatarUrl,
      radius: 17,
      devicePixelRatio: 3,
    );

    expect(identical(compact, compactAgain), isTrue);
    expect(identical(compact, large), isFalse);
    expect(identical(compact, dense), isFalse);
    expect(compact.maxWidth, 34);
    expect(compact.maxHeight, 34);
    expect(large.maxWidth, 48);
    expect(large.maxHeight, 48);
    expect(dense.maxWidth, 102);
    expect(dense.maxHeight, 102);
  });
}
