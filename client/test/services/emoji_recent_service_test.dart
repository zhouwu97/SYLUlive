import 'package:flutter_test/flutter_test.dart';

import '../../lib/services/emoji_recent_service.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


void main() {
  test('stores recent Emoji in newest-first order and removes duplicates',
      () async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    await service.record('😀');
    await service.record('❤️');
    await service.record('😀');

    expect(await service.load(), ['😀', '❤️']);

    final reloadedService = EmojiRecentService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    expect(await reloadedService.load(), ['😀', '❤️']);
  });

  test('keeps at most 32 recent Emoji', () async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiRecentService(
      preferencesLoader: AppPreferencesStore.getInstance,
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
