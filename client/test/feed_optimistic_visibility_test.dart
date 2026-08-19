import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/post_provider.dart';

Post _post(int id, int authorId) => Post(
      id: id,
      content: '内容 $id',
      boardId: 1,
      authorId: authorId,
      createdAt: DateTime.utc(2026, 8, 1),
    );

Map<String, dynamic> _feedJson(List<int> postIds) => {
      'posts': [
        for (final id in postIds)
          {
            'id': id,
            'content': '内容 $id',
            'board_id': 1,
            'author_id': id == 3 ? 7 : id,
            'created_at': '2026-08-01T00:00:00Z',
          },
      ],
      'pinned_posts': <Map<String, dynamic>>[],
      'total': postIds.length,
    };

Dio _feedDio({bool failFeedWrite = false, bool failFeedUndo = false}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/posts' || options.path == '/posts/featured') {
          final sort = options.queryParameters['sort'];
          // 每个 sort 返回帖子 1,2,3；作者 7 的帖子为 id3。
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _feedJson([1, 2, 3]),
            ),
          );
          return;
        }
        if (options.path.startsWith('/feed/')) {
          if (failFeedWrite ||
              (failFeedUndo && options.method.toUpperCase() == 'DELETE')) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'offline',
              ),
            );
          } else {
            handler.resolve(
              Response(
                  requestOptions: options, statusCode: 200, data: {'ok': true}),
            );
          }
          return;
        }
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: <dynamic>[]),
        );
      },
    ),
  );
  return dio;
}

Future<PostProvider> _loadedProvider(Dio dio) async {
  final provider = PostProvider(dio, enableCache: false);
  await provider.loadPosts(boardId: 1, sort: 'all');
  await provider.loadPosts(boardId: 1, sort: 'time');
  await provider.loadPosts(boardId: 1, sort: 'featured');
  await provider.loadPosts(boardId: 1, sort: 'following');
  return provider;
}

void main() {
  test('不感兴趣：本地从 all 移除，不移 time；撤销原位恢复', () async {
    final provider = await _loadedProvider(_feedDio());
    expect(provider.postsFor(1, sort: 'all').length, 3);
    expect(provider.postsFor(1, sort: 'time').length, 3);

    final post = provider.postsFor(1, sort: 'all').firstWhere((p) => p.id == 3);
    final undo =
        await provider.markPostNotInterestedOptimistic(post, source: 'all');
    expect(undo, isNotNull);

    expect(
        provider.postsFor(1, sort: 'all').map((p) => p.id), isNot(contains(3)));
    expect(provider.postsFor(1, sort: 'time').map((p) => p.id), contains(3),
        reason: '不感兴趣只移 all，不移 time');

    await provider.undoFeedVisibility(undo!);
    expect(provider.postsFor(1, sort: 'all').map((p) => p.id), contains(3),
        reason: '撤销后原位恢复');
  });

  test('不看TA：从 all/time/featured/following 全部移除该作者；撤销恢复', () async {
    final provider = await _loadedProvider(_feedDio());
    for (final sort in ['all', 'time', 'featured', 'following']) {
      expect(provider.postsFor(1, sort: sort).map((p) => p.id), contains(3));
    }

    final undo = await provider.hideAuthorOptimistic(7);
    expect(undo, isNotNull);
    for (final sort in ['all', 'time', 'featured', 'following']) {
      expect(
          provider.postsFor(1, sort: sort).map((p) => p.id), isNot(contains(3)),
          reason: '不看TA 对所有 Tab 生效: $sort');
    }

    await provider.undoFeedVisibility(undo!);
    for (final sort in ['all', 'time', 'featured', 'following']) {
      expect(provider.postsFor(1, sort: sort).map((p) => p.id), contains(3),
          reason: '撤销后恢复: $sort');
    }
  });

  test('服务端写入失败时回滚乐观状态', () async {
    final provider = await _loadedProvider(_feedDio(failFeedWrite: true));
    final post = provider.postsFor(1, sort: 'all').firstWhere((p) => p.id == 3);

    final undo =
        await provider.markPostNotInterestedOptimistic(post, source: 'all');
    expect(undo, isNull, reason: '失败不返回撤销记录');
    expect(provider.postsFor(1, sort: 'all').map((p) => p.id), contains(3),
        reason: '失败回滚');
  });

  test('撤销接口失败时不恢复本地隐藏状态', () async {
    final provider = await _loadedProvider(_feedDio(failFeedUndo: true));
    final post = provider.postsFor(1, sort: 'all').firstWhere((p) => p.id == 3);

    final undo = await provider.markPostNotInterestedOptimistic(
      post,
      source: 'all',
    );
    expect(undo, isNotNull);
    expect(
        provider.postsFor(1, sort: 'all').map((p) => p.id), isNot(contains(3)));

    final restored = await provider.undoFeedVisibility(undo!);
    expect(restored, isFalse);
    expect(
        provider.postsFor(1, sort: 'all').map((p) => p.id), isNot(contains(3)));
  });
}
