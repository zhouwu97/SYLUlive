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

  test('migrates v1 favorites to v2 when user logs in and marks migration flag',
      () async {
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: jsonEncode([
        {'type': 'sticker', 'sticker_id': 'legacy-sticker'},
        {'type': 'image', 'image_url': '/uploads/legacy.png'},
      ]),
    });

    final service = EmojiFavoriteService(
      userId: '100',
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    final items = await service.load();
    expect(items, hasLength(2));
    expect(items.map((e) => e.key), [
      'sticker:legacy-sticker',
      'image:/uploads/legacy.png',
    ]);

    final preferences = await AppPreferencesStore.getInstance();
    expect(
      preferences.getBool('emoji_favorites_v1_migrated_100'),
      isTrue,
    );
    // 迁移成功后：全局旧 v1 key 被清除，避免后续切换账号时被二次摄入；
    // 数据落在该账号专属的 v2 缓存 key 下，作为灾备恢复依据。
    expect(preferences.getString(EmojiFavoriteService.storageKey), isNull);
    final migratedV2 = preferences.getString('emoji_favorites_cache_v2_100');
    expect(migratedV2, isNotNull);
    expect(jsonDecode(migratedV2!), hasLength(2));
  });

  test('toggleImage calls repository to create cloud favorite when user logged in',
      () async {
    AppPreferencesStore.setMockInitialValues({});
    var createdFromPublicImage = false;
    final dio = Dio()
      ..httpClientAdapter = _EmojiAdapter((options) async {
        if (options.path == '/emoji/favorites/from-public-image') {
          createdFromPublicImage = true;
          return ResponseBody.fromString(
            jsonEncode({
              'id': 99,
              'kind': 'custom',
              'file_id': 123,
              'url': '/api/emoji/favorites/99/file',
              'thumbnail_url': '/api/emoji/favorites/99/thumbnail',
            }),
            201,
            headers: {
              Headers.contentTypeHeader: ['application/json']
            },
          );
        }
        return ResponseBody.fromString(
          jsonEncode({
            'items': [],
            'quota_used': 0,
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
      userId: '100',
      repository: EmojiFavoriteRepository(dio),
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    expect(await service.toggleImage('/uploads/post_pic.png'), isTrue);
    expect(createdFromPublicImage, isTrue);
    final items = await service.load();
    expect(items.first.serverId, 99);
  });

  test('迁移崩溃窗口：claim 归 A 时 B 不认领 v1，A 可继续完成且清理 claim/v1',
      () async {
    // 模拟 A 迁移中途崩溃：claim=A、v1 仍在、A 的 migrated 已写且 v2 已写，
    // 但 remove(v1)/remove(claim) 尚未执行。
    AppPreferencesStore.setMockInitialValues({
      EmojiFavoriteService.storageKey: jsonEncode([
        {'type': 'sticker', 'sticker_id': 'legacy-sticker'},
      ]),
      EmojiFavoriteService.migrationClaimKey: 'A',
    });

    // B 登录：claim 归 A，B 不得认领全局 v1
    final serviceB = EmojiFavoriteService(
      userId: 'B',
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    final bItems = await serviceB.load();
    expect(bItems, isEmpty);
    final preferences = await AppPreferencesStore.getInstance();
    expect(
      preferences.getString(EmojiFavoriteService.storageKey),
      isNotNull,
      reason: 'v1 仍归 A，B 不应消费',
    );

    // A 继续登录：claim==A 允许完成迁移，随后清理 v1 与 claim
    final serviceA = EmojiFavoriteService(
      userId: 'A',
      preferencesLoader: AppPreferencesStore.getInstance,
    );
    final aItems = await serviceA.load();
    expect(aItems.map((e) => e.key), ['sticker:legacy-sticker']);
    expect(preferences.getString(EmojiFavoriteService.storageKey), isNull);
    expect(preferences.getString(EmojiFavoriteService.migrationClaimKey), isNull);
  });

  test('A 上传旧收藏途中切到 B：A 的同步结果不写入 B 的缓存键', () async {
    // 预置 A 的本地旧收藏（serverId==null），触发 _syncRemote 的云端上传
    AppPreferencesStore.setMockInitialValues({
      'emoji_favorites_v1_migrated_A': true,
      'emoji_favorites_cache_v2_A': jsonEncode([
        {'type': 'sticker', 'sticker_id': 'legacy-A'},
      ]),
    });

    final blockedBuiltin = Completer<ResponseBody>();
    var uploads = 0;
    final dio = Dio()
      ..httpClientAdapter = _EmojiAdapter((options) async {
        if (options.path == '/emoji/favorites' && options.method == 'POST') {
          uploads++;
          // 阻塞 A 的 createBuiltin，制造切号窗口
          return blockedBuiltin.future;
        }
        return ResponseBody.fromString(
          jsonEncode({'items': []}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          },
        );
      });

    final service = EmojiFavoriteService(
      userId: 'A',
      repository: EmojiFavoriteRepository(dio),
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    // A 开始 load：读本地旧收藏 → 触发 sync，上传停在 createBuiltin
    final loadA = service.load();
    var ticks = 0;
    while (uploads == 0 && ticks < 100) {
      await Future<void>.delayed(Duration.zero);
      ticks++;
    }
    expect(uploads, 1, reason: 'A 的上传必须进入阻塞窗口');

    // 在 A 上传完成前切到 B
    service.switchUser('B');

    // 放行 A 的上传
    blockedBuiltin.complete(
      ResponseBody.fromString(
        jsonEncode({
          'id': 7,
          'kind': 'builtin',
          'sticker_id': 'legacy-A',
        }),
        201,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      ),
    );
    await loadA;

    // A 的过时同步绝不能写入 B 的缓存键
    final preferences = await AppPreferencesStore.getInstance();
    expect(preferences.getString('emoji_favorites_cache_v2_B'), isNull);
  });

  test('A addCustomFromUpload 阻塞期间切到 B：A 的 item 不写入 B 缓存', () async {
    AppPreferencesStore.setMockInitialValues({
      'emoji_favorites_v1_migrated_A': true,
    });

    final blockedCustom = Completer<ResponseBody>();
    var createCalls = 0;
    final dio = Dio()
      ..httpClientAdapter = _EmojiAdapter((options) async {
        if (options.path == '/emoji/favorites' && options.method == 'POST') {
          createCalls++;
          return blockedCustom.future;
        }
        return ResponseBody.fromString(
          jsonEncode({'items': []}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          },
        );
      });

    final service = EmojiFavoriteService(
      userId: 'A',
      repository: EmojiFavoriteRepository(dio),
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    final upload = service.addCustomFromUpload(500);
    var ticks = 0;
    while (createCalls == 0 && ticks < 100) {
      await Future<void>.delayed(Duration.zero);
      ticks++;
    }
    expect(createCalls, 1, reason: 'A 的 createCustom 必须进入阻塞窗口');

    service.switchUser('B');

    blockedCustom.complete(
      ResponseBody.fromString(
        jsonEncode({
          'id': 77,
          'kind': 'custom',
          'file_id': 500,
          'url': '/api/emoji/favorites/77/file',
        }),
        201,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      ),
    );
    await expectLater(upload, throwsA(isA<EmojiFavoriteException>()));

    final preferences = await AppPreferencesStore.getInstance();
    expect(preferences.getString('emoji_favorites_cache_v2_B'), isNull);
  });

  test('A addFromMessage 阻塞期间切到 B：A 的 item 不写入 B 缓存', () async {
    AppPreferencesStore.setMockInitialValues({
      'emoji_favorites_v1_migrated_A': true,
    });

    final blockedMsg = Completer<ResponseBody>();
    var messageCalls = 0;
    final dio = Dio()
      ..httpClientAdapter = _EmojiAdapter((options) async {
        if (options.path == '/emoji/favorites/from-message') {
          messageCalls++;
          return blockedMsg.future;
        }
        return ResponseBody.fromString(
          jsonEncode({'items': []}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          },
        );
      });

    final service = EmojiFavoriteService(
      userId: 'A',
      repository: EmojiFavoriteRepository(dio),
      preferencesLoader: AppPreferencesStore.getInstance,
    );

    final addMsg = service.addFromMessage(3001);
    var ticks = 0;
    while (messageCalls == 0 && ticks < 100) {
      await Future<void>.delayed(Duration.zero);
      ticks++;
    }
    expect(messageCalls, 1, reason: 'A 的 createFromMessage 必须进入阻塞窗口');

    service.switchUser('B');

    blockedMsg.complete(
      ResponseBody.fromString(
        jsonEncode({
          'id': 88,
          'kind': 'custom',
          'file_id': 501,
          'url': '/api/emoji/favorites/88/file',
        }),
        201,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      ),
    );
    await expectLater(addMsg, throwsA(isA<EmojiFavoriteException>()));

    final preferences = await AppPreferencesStore.getInstance();
    expect(preferences.getString('emoji_favorites_cache_v2_B'), isNull);
  });
}

