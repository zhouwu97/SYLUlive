import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/post_cache_service.dart';

Map<String, dynamic> _postJson(int id) {
  return {
    'id': id,
    'title': 'post-$id',
    'content': 'content-$id',
    'board_id': 1,
    'author_id': 1,
    'created_at': '2026-06-14T08:00:00Z',
  };
}

Response<dynamic> _response(RequestOptions options, int postId) {
  return Response(
    requestOptions: options,
    statusCode: 200,
    data: {
      'posts': [_postJson(postId)],
      'total': 1,
      'session_id': 'session-$postId',
    },
  );
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('post-cache-test-');
    Hive.init(hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDir.exists()) {
      await hiveDir.delete(recursive: true);
    }
  });

  test('different feed sorts keep independent results', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final sort = options.queryParameters['sort'];
          await Future<void>.delayed(
            Duration(milliseconds: sort == 'all' ? 50 : 5),
          );
          handler.resolve(_response(options, sort == 'all' ? 10 : 20));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    await Future.wait([
      provider.refresh(boardId: 1, sort: 'all'),
      provider.refresh(boardId: 1, sort: 'hot'),
    ]);

    expect(provider.postsFor(1, sort: 'all').single.id, 10);
    expect(provider.postsFor(1, sort: 'hot').single.id, 20);
  });

  test('refresh keeps the existing list visible', () async {
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requestCount++;
          if (requestCount == 2) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          handler.resolve(_response(options, requestCount));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);
    await provider.refresh(boardId: 1, sort: 'all');

    final refresh = provider.refresh(boardId: 1, sort: 'all');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(provider.postsFor(1, sort: 'all').single.id, 1);
    expect(provider.isLoadingFor(1, sort: 'all'), isFalse);
    await refresh;
    expect(provider.postsFor(1, sort: 'all').single.id, 2);
  });

  test('in-flight exact duplicate requests are merged', () async {
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requestCount++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          handler.resolve(_response(options, requestCount));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    await Future.wait([
      provider.refresh(boardId: 1, sort: 'hot'),
      provider.refresh(boardId: 1, sort: 'hot'),
    ]);

    expect(requestCount, 1);
    expect(provider.postsFor(1, sort: 'hot').single.id, 1);
  });

  test('cached first load refreshes latest page without since anchor',
      () async {
    final oldAuthor = User(
      id: 7,
      studentId: 'old',
      nickname: 'Old',
      createdAt: DateTime.utc(2026, 6, 14),
    );
    await PostCacheService.savePosts(
      99,
      [
        Post(
          id: 1,
          content: 'cached',
          boardId: 99,
          authorId: oldAuthor.id,
          author: oldAuthor,
          createdAt: DateTime.utc(2026, 6, 14, 8),
        ),
      ],
      sort: 'time',
    );

    final dio = Dio();
    final seenSinceParams = <dynamic>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          seenSinceParams.add(options.queryParameters['since']);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'posts': [
                  {
                    'id': 1,
                    'title': 'post-1',
                    'content': 'cached',
                    'board_id': 99,
                    'author_id': 7,
                    'created_at': '2026-06-14T08:00:00Z',
                    'author': {
                      'id': 7,
                      'student_id': 'new',
                      'nickname': 'New',
                      'avatar': '/uploads/new-avatar.jpg',
                      'created_at': '2026-06-14T08:00:00Z',
                    },
                  },
                ],
                'total': 1,
              },
            ),
          );
        },
      ),
    );

    final provider = PostProvider(dio);
    await provider.loadPosts(boardId: 99, sort: 'time');

    expect(seenSinceParams, [null]);
    expect(provider.postsFor(99, sort: 'time').single.author?.avatar,
        '/uploads/new-avatar.jpg');
  });

  test('post pin fields parse active state and copyWith can clear pin times',
      () {
    final futureUntil = DateTime.now().add(const Duration(days: 1));
    final post = Post.fromJson({
      'id': 1,
      'content': 'content',
      'board_id': 1,
      'author_id': 1,
      'is_pinned': true,
      'pinned_at': DateTime.now().toUtc().toIso8601String(),
      'pinned_until': futureUntil.toUtc().toIso8601String(),
      'pinned_by': 99,
      'pinned_weight': 80,
      'pinned_reason': '测试置顶',
      'created_at': '2026-06-14T08:00:00Z',
    });

    expect(post.isActivePinned, isTrue);
    expect(post.pinnedBy, 99);
    expect(post.pinnedWeight, 80);

    final cleared = post.copyWith(
      isPinned: false,
      pinnedBy: 0,
      pinnedWeight: 0,
      pinnedReason: '',
      clearPinnedAt: true,
      clearPinnedUntil: true,
    );
    expect(cleared.isPinned, isFalse);
    expect(cleared.pinnedAt, isNull);
    expect(cleared.pinnedUntil, isNull);

    final expired = post.copyWith(
      pinnedUntil: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(expired.isActivePinned, isFalse);
  });

  test('post cache preserves pin and featured metadata', () async {
    final pinnedUntil = DateTime.utc(2026, 6, 17);
    await PostCacheService.savePosts(
      88,
      [
        Post(
          id: 8,
          content: 'cached',
          boardId: 88,
          authorId: 1,
          replyCount: 3,
          likeCount: 4,
          isPinned: true,
          pinnedAt: DateTime.utc(2026, 6, 14),
          pinnedUntil: pinnedUntil,
          pinnedBy: 99,
          pinnedWeight: 70,
          pinnedReason: '缓存测试',
          isFeatured: true,
          featuredAt: DateTime.utc(2026, 6, 15),
          featuredBy: 2,
          featuredReason: '精华测试',
          createdAt: DateTime.utc(2026, 6, 14, 8),
          updatedAt: DateTime.utc(2026, 6, 16, 8),
        ),
      ],
      sort: 'all',
    );

    final loaded = await PostCacheService.loadPosts(88, sort: 'all');
    expect(loaded.single.replyCount, 3);
    expect(loaded.single.likeCount, 4);
    expect(loaded.single.isPinned, isTrue);
    expect(loaded.single.pinnedUntil, pinnedUntil);
    expect(loaded.single.pinnedWeight, 70);
    expect(loaded.single.isFeatured, isTrue);
    expect(loaded.single.featuredBy, 2);
  });

  test('pin and unpin replace matching posts in local feeds', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/posts') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'posts': [_postJson(1)],
                  'total': 1,
                },
              ),
            );
            return;
          }
          if (options.path == '/admin/posts/1/pin') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  ..._postJson(1),
                  'is_pinned': true,
                  'pinned_at': '2026-06-14T08:00:00Z',
                  'pinned_until': '2026-06-17T08:00:00Z',
                  'pinned_by': 99,
                  'pinned_weight': 50,
                  'pinned_reason': '置顶',
                },
              ),
            );
            return;
          }
          if (options.path == '/admin/posts/1/unpin') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  ..._postJson(1),
                  'is_pinned': false,
                  'pinned_at': null,
                  'pinned_until': null,
                  'pinned_by': 0,
                  'pinned_weight': 0,
                  'pinned_reason': '',
                },
              ),
            );
            return;
          }
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.refresh(boardId: 1, sort: 'time');

    final pinResult = await provider.pinPost(
      postId: 1,
      pinnedUntil: DateTime.utc(2026, 6, 17, 8),
    );
    expect(pinResult.success, isTrue);
    expect(provider.postsFor(1, sort: 'time').single.isPinned, isTrue);

    final unpinResult = await provider.unpinPost(1);
    expect(unpinResult.success, isTrue);
    final post = provider.postsFor(1, sort: 'time').single;
    expect(post.isPinned, isFalse);
    expect(post.pinnedUntil, isNull);
  });

  test('refreshHomePinnedFeeds refreshes all and time but not following',
      () async {
    final dio = Dio();
    final seenSorts = <String>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          seenSorts.add(options.queryParameters['sort']?.toString() ?? '');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'posts': <Map<String, dynamic>>[],
                'total': 0,
              },
            ),
          );
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.refreshHomePinnedFeeds();

    expect(seenSorts, containsAll(['all', 'time']));
    expect(seenSorts, isNot(contains('following')));
  });
}
