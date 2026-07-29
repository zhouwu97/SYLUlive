import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';

void main() {
  test('persists sticker and image favorites newest first', () async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    expect(await service.toggleSticker('sticker-1'), isTrue);
    expect(await service.toggleImage('/uploads/favorite.png'), isTrue);

    final items = await service.load();
    expect(items.map((item) => item.key), [
      'image:/uploads/favorite.png',
      'sticker:sticker-1',
    ]);

    final preferences = await AppPreferencesStore.getInstance();
    final stored =
        jsonDecode(preferences.getString(EmojiFavoriteService.storageKey)!)
            as List<dynamic>;
    expect(stored, hasLength(2));
  });

  test('toggle removes an existing favorite and ignores corrupt records',
      () async {
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: jsonEncode([
        {'type': 'sticker', 'sticker_id': 'sticker-1'},
        {'type': 'unknown'},
        'broken',
      ]),
    });
    final service = EmojiFavoriteService(
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    expect(await service.containsSticker('sticker-1'), isTrue);
    expect(await service.toggleSticker('sticker-1'), isFalse);
    expect(await service.load(), isEmpty);
  });
}
