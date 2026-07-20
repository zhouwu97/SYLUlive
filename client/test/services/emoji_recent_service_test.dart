import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/services/emoji_recent_service.dart';

void main() {
  test('stores recent Emoji in newest-first order and removes duplicates',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: SharedPreferences.getInstance,
    );

    await service.record('😀');
    await service.record('❤️');
    await service.record('😀');

    expect(await service.load(), ['😀', '❤️']);

    final reloadedService = EmojiRecentService(
      preferencesLoader: SharedPreferences.getInstance,
    );
    expect(await reloadedService.load(), ['😀', '❤️']);
  });

  test('keeps at most 32 recent Emoji', () async {
    SharedPreferences.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: SharedPreferences.getInstance,
    );

    for (var index = 0; index < 40; index++) {
      await service.record('emoji-$index');
    }

    final recent = await service.load();
    expect(recent, hasLength(32));
    expect(recent.first, 'emoji-39');
    expect(recent.last, 'emoji-8');
  });
}
