import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/emoji_favorite_repository.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream< List<int> >? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: <String>['application/json'],
    },
  );
}

void main() {
  test('parses custom animated item and quota fields', () {
    final item = EmojiFavoriteItem.fromApiJson({
      'id': 9,
      'kind': 'custom',
      'asset_id': 12,
      'file_id': 33,
      'url': '/uploads/a.gif',
      'thumbnail_url': '/uploads/a_thumb.png',
      'mime_type': 'image/gif',
      'is_animated': true,
      'sort_order': 1,
      'compressed_size': 1024,
      'quota_used': 1024,
    });

    expect(item.serverId, 9);
    expect(item.assetId, 12);
    expect(item.fileId, 33);
    expect(item.thumbnailUrl, '/uploads/a_thumb.png');
    expect(item.isAnimated, isTrue);
    expect(item.compressedSize, 1024);
    expect(item.quotaUsed, 1024);
    expect(item.type, EmojiFavoriteType.image);
  });

  test('repository posts message id instead of image URL', () async {
    late _RecordingAdapter adapter;
    adapter = _RecordingAdapter((options) async {
      expect(options.method, 'POST');
      expect(options.path, '/emoji/favorites/from-message');
      expect(options.data, {'message_id': 42});
      return _jsonResponse({
        'id': 7,
        'kind': 'custom',
        'file_id': 33,
        'url': '/uploads/a.gif',
      });
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final item = await EmojiFavoriteRepository(dio).createFromMessage(42);

    expect(item.serverId, 7);
    expect(adapter.requests, hasLength(1));
  });

  test('account cache keys isolate two users while preserving legacy no-user key',
      () async {
    final first = EmojiFavoriteService(userId: '7');
    final second = EmojiFavoriteService(userId: '8');
    expect(first.accountStorageKey, isNot(second.accountStorageKey));
    expect(first.accountStorageKey, contains('7'));
    expect(second.accountStorageKey, contains('8'));
    expect(EmojiFavoriteService().accountStorageKey,
        EmojiFavoriteService.storageKey);
  });

  test('account cache contents do not leak after switching users', () async {
    AppPreferencesStore.setMockInitialValues({});
    final service = EmojiFavoriteService(userId: '7');
    await service.add(const EmojiFavoriteItem.sticker('s7'));

    service.switchUser('8');
    expect(await service.load(), isEmpty);
    await service.add(const EmojiFavoriteItem.sticker('s8'));

    service.switchUser('7');
    expect((await service.load()).single.stickerId, 's7');
  });

  test('parses list quota response and ignores malformed rows', () {
    final page = EmojiFavoritePage.fromJson({
      'items': [
        {
          'id': 1,
          'kind': 'builtin',
          'sticker_id': 's1',
        },
        {'kind': 'unknown'},
      ],
      'quota_used': '1024',
      'quota_limit': 52428800,
      'favorite_limit': 80,
    });

    expect(page.items.single.stickerId, 's1');
    expect(page.quotaUsed, 1024);
    expect(page.quotaLimit, 52428800);
    expect(page.favoriteLimit, 80);
  });

  test('v1 legacy favorites migrate to first user and do not leak to second user', () async {
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: '[{"kind":"builtin","sticker_id":"legacy_s1"}]',
    });

    final serviceUser1 = EmojiFavoriteService(userId: 'user1');
    final user1Items = await serviceUser1.load();
    expect(user1Items.length, 1);
    expect(user1Items.first.stickerId, 'legacy_s1');

    final serviceUser2 = EmojiFavoriteService(userId: 'user2');
    final user2Items = await serviceUser2.load();
    expect(user2Items, isEmpty);
  });
}
