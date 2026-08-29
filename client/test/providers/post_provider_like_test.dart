import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/post_provider.dart';

Map<String, dynamic> _postJson(
  int id, {
  bool isLiked = false,
  int likeCount = 12,
}) {
  return {
    'id': id,
    'title': '帖子 $id',
    'content': '内容 $id',
    'board_id': 1,
    'author_id': 1,
    'created_at': '2026-08-01T00:00:00Z',
    'is_liked': isLiked,
    'like_count': likeCount,
  };
}

Post _post({int id = 1, bool isLiked = false, int likeCount = 12}) {
  return Post(
    id: id,
    title: '帖子 $id',
    content: '内容 $id',
    boardId: 1,
    authorId: 1,
    createdAt: DateTime(2026, 8, 1),
    isLiked: isLiked,
    likeCount: likeCount,
  );
}

/// 预置两个信息流（all / time），各自包含同一帖子。
Future<PostProvider> _providerWithBoards(Dio dio) async {
  final provider = PostProvider(dio, enableCache: false);
  await Future.wait([
    provider.refresh(boardId: 1, sort: 'all'),
    provider.refresh(boardId: 1, sort: 'time'),
  ]);
  return provider;
}

Response<dynamic> _feedResponse(RequestOptions options) {
  return Response(
    requestOptions: options,
    statusCode: 200,
    data: <String, dynamic>{
      'posts': [_postJson(1)],
      'pinned_posts': <dynamic>[],
      'total': 1,
      'session_id': 's',
      'algorithm_version': 'v1',
    },
  );
}

void main() {
  test('乐观点赞立即翻转并同步到所有信息流', () async {
    final likeGate = Completer<void>();
    final requests = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add('${options.method} ${options.path}');
          if (options.path == '/posts/1/like') {
            await likeGate.future;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <dynamic>[],
              ),
            );
            return;
          }
          handler.resolve(_feedResponse(options));
        },
      ),
    );

    final provider = await _providerWithBoards(dio);
    expect(provider.postsFor(1, sort: 'all').single.isLiked, isFalse);

    final future = provider.toggleLikeOptimistic(_post());

    // 网络未返回时，所有信息流已乐观翻转。
    expect(provider.postsFor(1, sort: 'all').single.isLiked, isTrue);
    expect(provider.postsFor(1, sort: 'all').single.likeCount, 13);
    expect(provider.postsFor(1, sort: 'time').single.isLiked, isTrue);
    expect(provider.postsFor(1, sort: 'time').single.likeCount, 13);
    expect(provider.isLikePending(1), isTrue);

    likeGate.complete();
    final result = await future;
    expect(result.status, LikeMutationStatus.success);
    expect(result.optimisticPost?.isLiked, isTrue);
    expect(provider.isLikePending(1), isFalse);
    expect(requests.where((r) => r == 'POST /posts/1/like'), hasLength(1));
  });

  test('网络失败回滚到变更前快照', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/posts/1/like') {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'offline',
              ),
            );
            return;
          }
          handler.resolve(_feedResponse(options));
        },
      ),
    );

    final provider = await _providerWithBoards(dio);
    final result = await provider.toggleLikeOptimistic(_post());

    expect(result.status, LikeMutationStatus.failed);
    expect(provider.postsFor(1, sort: 'all').single.isLiked, isFalse);
    expect(provider.postsFor(1, sort: 'all').single.likeCount, 12);
    expect(provider.postsFor(1, sort: 'time').single.likeCount, 12);
    expect(provider.isLikePending(1), isFalse);
  });

  test('服务端明确冲突时用单次 GET reconcile，不盲目回滚', () async {
    final requests = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add('${options.method} ${options.path}');
          if (options.path == '/posts/1/like') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 400,
                  // 服务端统一错误格式 {code, message, request_id}
                  data: <String, dynamic>{
                    'code': 'post_like_conflict',
                    'message': 'already liked',
                    'request_id': 'req-test',
                  },
                ),
              ),
            );
            return;
          }
          if (options.path == '/posts/1') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _postJson(1, isLiked: true, likeCount: 99),
              ),
            );
            return;
          }
          handler.resolve(_feedResponse(options));
        },
      ),
    );

    final provider = await _providerWithBoards(dio);
    final result = await provider.toggleLikeOptimistic(_post());

    expect(result.status, LikeMutationStatus.conflict);
    expect(result.reconciledPost?.isLiked, isTrue);
    // 服务端状态覆盖本地（likeCount 99），而不是回滚成未点赞。
    expect(provider.postsFor(1, sort: 'all').single.isLiked, isTrue);
    expect(provider.postsFor(1, sort: 'all').single.likeCount, 99);
    expect(provider.postsFor(1, sort: 'time').single.isLiked, isTrue);
    expect(requests, contains('GET /posts/1'));
    // reconcile 只拉单帖，不重新拉取列表（两次 GET /posts 来自预置刷新）。
    expect(requests.where((r) => r == 'GET /posts').length, 2);
  });

  test('同一帖子变更在途时第二次点击不发请求（防连点）', () async {
    final likeGate = Completer<void>();
    var likeRequestCount = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/posts/1/like') {
            likeRequestCount++;
            await likeGate.future;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <dynamic>[],
              ),
            );
            return;
          }
          handler.resolve(_feedResponse(options));
        },
      ),
    );

    final provider = await _providerWithBoards(dio);
    final first = provider.toggleLikeOptimistic(_post());

    // 让出事件循环，确保第一次请求的拦截器已进入（likeRequestCount 递增）。
    await Future<void>.delayed(Duration.zero);

    final second = await provider.toggleLikeOptimistic(_post());

    expect(second.status, LikeMutationStatus.pending);

    likeGate.complete();
    final firstResult = await first;
    expect(firstResult.status, LikeMutationStatus.success);
    expect(likeRequestCount, 1);
  });

  test('取消点赞走 DELETE 并乐观减一', () async {
    final requests = <String>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add('${options.method} ${options.path}');
          if (options.path == '/posts/1/like') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <dynamic>[],
              ),
            );
            return;
          }
          handler.resolve(_feedResponse(options));
        },
      ),
    );

    final provider = await _providerWithBoards(dio);
    final result = await provider
        .toggleLikeOptimistic(_post(isLiked: true, likeCount: 20));

    expect(result.status, LikeMutationStatus.success);
    expect(requests, contains('DELETE /posts/1/like'));
    expect(provider.postsFor(1, sort: 'all').single.isLiked, isFalse);
    expect(provider.postsFor(1, sort: 'all').single.likeCount, 19);
  });
}
