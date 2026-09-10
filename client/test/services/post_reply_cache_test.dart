import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/post_reply_cache.dart';

class _ReplyDio extends Fake implements Dio {
  int calls = 0;
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<Response<T>> get<T>(String path,
      {Object? data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      ProgressCallback? onReceiveProgress}) async {
    final count = ++calls;
    await pending?.future;
    if (fail) throw StateError('offline');
    return Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {
          'replies': <dynamic>[],
          'total': count,
          'next_cursor': queryParameters?['cursor'],
        } as T);
  }
}

void main() {
  test('30 秒内复用，过期合并请求且等待时仍保留旧页', () async {
    var now = DateTime(2026);
    final dio = _ReplyDio();
    final cache = PostReplyCache(dio, now: () => now)..useScope('A');
    await cache.load(1, 'hot');
    await cache.load(1, 'hot');
    expect(dio.calls, 1);
    now = now.add(const Duration(seconds: 31));
    dio.pending = Completer<void>();
    final first = cache.load(1, 'hot');
    final second = cache.load(1, 'hot');
    expect(identical(first, second), isTrue);
    expect(cache.peek(1, 'hot')!.data['total'], 1);
    dio.pending!.complete();
    await first;
    expect(dio.calls, 2);
    expect(cache.peek(1, 'hot')!.data['total'], 2);
  });

  test('账号切换或写操作失效后，旧在途请求不能写回缓存', () async {
    final dio = _ReplyDio()..pending = Completer<void>();
    final cache = PostReplyCache(dio)..useScope('A');
    final request = cache.load(1, 'hot');
    cache.useScope('B');
    dio.pending!.complete();
    await request;
    expect(cache.peek(1, 'hot'), isNull);
    await cache.load(1, 'hot');
    cache.invalidate();
    expect(cache.peek(1, 'hot'), isNull);
    await cache.load(1, 'hot');
    expect(dio.calls, 3);
  });

  test('排序隔离、分页不覆盖首屏、缓存数量有上限', () async {
    final dio = _ReplyDio();
    final cache = PostReplyCache(dio)..useScope('A');
    await cache.load(1, 'hot');
    await cache.load(1, 'latest');
    await cache.load(1, 'hot', cursor: 'page2');
    expect(cache.peek(1, 'hot')!.data['total'], 1);
    expect(cache.peek(1, 'latest')!.data['total'], 2);
    for (var id = 2; id <= 21; id++) {
      await cache.load(id, 'hot');
    }
    expect(cache.peek(1, 'hot'), isNull);
    expect(cache.peek(21, 'hot'), isNotNull);
  });

  test('刷新失败保留旧数据且下次允许重试', () async {
    final dio = _ReplyDio();
    final cache = PostReplyCache(dio)..useScope('A');
    await cache.load(1, 'hot');
    dio.fail = true;
    await expectLater(cache.load(1, 'hot', force: true), throwsStateError);
    expect(cache.peek(1, 'hot'), isNotNull);
    dio.fail = false;
    await cache.load(1, 'hot', force: true);
    expect(dio.calls, 3);
  });
}
