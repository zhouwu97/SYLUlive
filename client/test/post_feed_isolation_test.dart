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
}
