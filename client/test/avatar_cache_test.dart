import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/cached_avatar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    final tempRoot = await Directory.systemTemp.createTemp('avatar_cache_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
        case 'getApplicationSupportDirectory':
        case 'getApplicationDocumentsDirectory':
          return tempRoot.path;
      }
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

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
