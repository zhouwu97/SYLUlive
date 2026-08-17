import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/services/emoji_favorite_repository.dart';

class _EmojiAdapter implements HttpClientAdapter {
  _EmojiAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

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

  test('loads account favorites from the repository and caches the result',
      () async {
    AppPreferencesStore.setMockInitialValues({});
    var fetchCount = 0;
    final dio = Dio()
      ..httpClientAdapter = _EmojiAdapter((options) async {
        expect(options.path, '/emoji/favorites');
        fetchCount++;
        return ResponseBody.fromString(
          jsonEncode({
            'items': [
              {
                'id': 11,
                'kind': 'custom',
                'file_id': 77,
                'url': '/api/emoji/favorites/11/file',
                'thumbnail_url': '/api/emoji/favorites/11/thumbnail',
                'is_animated': true,
              },
            ],
            'quota_used': 100,
            'quota_limit': 52428800,
            'favorite_limit': 80,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          },
        );
      });
    final service = EmojiFavoriteService(
      userId: '8',
      repository: EmojiFavoriteRepository(dio),
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    final first = await service.load();
    final second = await service.load();

    expect(first.single.fileId, 77);
    expect(first.single.isAnimated, isTrue);
    expect(second.single.key, first.single.key);
    expect(fetchCount, 1);
  });

  test('ignores a stale sync result after switching accounts', () async {
    AppPreferencesStore.setMockInitialValues({});
    final firstResponse = Completer<ResponseBody>();
    var fetchCount = 0;
    final dio = Dio()
      ..httpClientAdapter = _EmojiAdapter((options) async {
        fetchCount++;
        if (fetchCount == 1) return firstResponse.future;
        return ResponseBody.fromString(
          jsonEncode({
            'items': [
              {'kind': 'builtin', 'sticker_id': 'account-8-sticker'},
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          },
        );
      });
    final service = EmojiFavoriteService(
      userId: '7',
      repository: EmojiFavoriteRepository(dio),
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    final oldSync = service.syncFromServer();
    await Future<void>.delayed(Duration.zero);
    service.switchUser('8');
    firstResponse.complete(
      ResponseBody.fromString(
        jsonEncode({
          'items': [
            {'kind': 'builtin', 'sticker_id': 'account-7-sticker'},
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      ),
    );
    await oldSync;

    final items = await service.load();
    expect(items.single.stickerId, 'account-8-sticker');
    expect(fetchCount, 2);
  });
}
