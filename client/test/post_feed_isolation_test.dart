import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/post_provider.dart';

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

  test('stale response cannot overwrite a newer request', () async {
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requestCount++;
          final currentRequest = requestCount;
          await Future<void>.delayed(
            Duration(milliseconds: currentRequest == 1 ? 50 : 5),
          );
          handler.resolve(_response(options, currentRequest));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    await Future.wait([
      provider.refresh(boardId: 1, sort: 'hot'),
      provider.refresh(boardId: 1, sort: 'hot'),
    ]);

    expect(provider.postsFor(1, sort: 'hot').single.id, 2);
  });
}
