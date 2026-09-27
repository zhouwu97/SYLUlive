import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/services/post_cache_service.dart';

Map<String, dynamic> _postJson(int id, {String title = 'cached-title'}) {
  return {
    'id': id,
    'title': '$title-$id',
    'content': 'content-$id',
    'board_id': 1,
    'author_id': 1,
    'created_at': '2026-06-14T08:00:00Z',
  };
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('post-initial-cache-test-');
    Hive.init(hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDir.exists()) {
      await hiveDir.delete(recursive: true);
    }
  });

  tearDown(() async {
    PostCacheService.beforeCachePut = null;
    PostCacheService.activeSessionEpoch = 0;
    if (Hive.isBoxOpen('post_cache')) {
      final box = Hive.box<String>('post_cache');
      await box.clear();
    }
  });

  test(
      'ensureInitialFeed shows eligible cached posts BEFORE hanging network request returns',
      () async {
    // 1. 预先写入一份匹配当前 session epoch 的有效缓存
    final cachedPost = Post.fromJson(_postJson(999, title: 'cached'));
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [cachedPost]),
      sort: 'all',
      sessionEpoch: PostCacheService.activeSessionEpoch,
    );
    await PostCacheService.waitForPendingWrites();

    // 2. 创建一个挂起的网络请求 Completer
    final networkCompleter = Completer<Response<dynamic>>();
    var networkRequestCount = 0;

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          networkRequestCount++;
          // 等待挂起的 Completer 完成
          final res = await networkCompleter.future;
          handler.resolve(res);
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: true);

    // 3. 启动首屏初始化
    final initFuture = provider.ensureInitialFeed(boardId: 1, sort: 'all');

    // 让 microtask 和本地缓存读取调度执行
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 4. 关键断言：网络响应尚未返回时，缓存帖子必须已经发布并可见！
    expect(networkCompleter.isCompleted, isFalse, reason: '网络请求此时应当仍在挂起');
    expect(provider.postsFor(1, sort: 'all').length, 1,
        reason: '在网络返回前，页面必须已经能够看到本地缓存中的帖子');
    expect(provider.postsFor(1, sort: 'all').first.id, 999);
    expect(provider.postsFor(1, sort: 'all').first.title, 'cached-999');

    // 5. 并发再次调用 ensureInitialFeed：必须返回同一个在途 Future，不重复触发网络请求
    final secondInitFuture =
        provider.ensureInitialFeed(boardId: 1, sort: 'all');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(networkRequestCount, 1, reason: '在途初始化期间不应触发重复网络请求');

    // 6. 网络响应完成，返回新数据
    final networkPost = _postJson(888, title: 'network');
    networkCompleter.complete(
      Response(
        requestOptions: RequestOptions(path: '/api/posts'),
        statusCode: 200,
        data: {
          'posts': [networkPost],
          'total': 1,
          'session_id': 'sess-network',
        },
      ),
    );

    await Future.wait([initFuture, secondInitFuture]);

    // 7. 网络返回后，新帖子替换缓存帖子
    expect(provider.postsFor(1, sort: 'all').length, 1);
    expect(provider.postsFor(1, sort: 'all').first.id, 888);
    expect(provider.postsFor(1, sort: 'all').first.title, 'network-888');
    expect(provider.hasLoadedFor(1, sort: 'all'), isTrue);

    // 父页面可能在初始化完成后才读取门禁信号，此时不能再拿到一个永远未完成的 Future。
    await provider.initialFeedFuture.timeout(const Duration(milliseconds: 50));
  });

  test('首个 Feed 请求超过累计预算会取消请求并释放 loading', () async {
    CancelToken? observedToken;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          observedToken = options.cancelToken;
          options.cancelToken!.whenCancel.then((_) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.cancel,
              ),
            );
          });
        },
      ),
    );

    final provider = PostProvider(
      dio,
      enableCache: false,
      feedRequestBudget: const Duration(milliseconds: 40),
    );
    final stopwatch = Stopwatch()..start();
    await provider.ensureInitialFeed(boardId: 1, sort: 'all');
    stopwatch.stop();

    expect(observedToken, isNotNull);
    expect(observedToken!.isCancelled, isTrue);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(provider.isLoadingFor(1, sort: 'all'), isFalse);
  });

  test('切换会话后旧世代的首页缓存不能被新会话读取', () async {
    final oldPost = Post.fromJson(_postJson(701, title: 'old-session'));
    final write = PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [oldPost]),
      sort: 'all',
      sessionEpoch: PostCacheService.activeSessionEpoch,
    );
    PostCacheService.incrementSessionEpoch();
    await write;

    final cached = await PostCacheService.loadPosts(
      1,
      sort: 'all',
      expectedSessionEpoch: PostCacheService.activeSessionEpoch,
    );
    expect(cached, isNull);
  });

  test('写缓存失败时清理仍完成且新会话读不到旧缓存', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    PostCacheService.beforeCachePut = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      throw StateError('模拟旧会话写入失败');
    };

    final oldSave = PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [Post.fromJson(_postJson(702, title: 'old'))]),
      sort: 'all',
      sessionEpoch: PostCacheService.activeSessionEpoch,
    );
    await entered.future;
    PostCacheService.incrementSessionEpoch();

    final clear = PostCacheService.clearBoard(1);
    release.complete();
    await expectLater(oldSave, throwsStateError);
    await clear;

    final box = Hive.box<String>('post_cache');
    expect(
      box.keys.where((key) => key.toString().startsWith('board_1_')),
      isEmpty,
    );
    expect(
      await PostCacheService.loadPosts(
        1,
        sort: 'all',
        expectedSessionEpoch: PostCacheService.activeSessionEpoch,
      ),
      isNull,
    );
  });

  test('旧会话的首屏请求结束后不能提前完成新会话初始化信号', () async {
    final pendingResponses = <Completer<Response<dynamic>>>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final response = Completer<Response<dynamic>>();
          pendingResponses.add(response);
          response.future.then(handler.resolve);
          options.cancelToken?.whenCancel.then((_) {
            if (!response.isCompleted) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                ),
              );
            }
          });
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    final oldInitialization = provider.ensureInitialFeed(boardId: 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(pendingResponses, hasLength(1));

    await provider.invalidateHomeFeedCaches();
    final newInitialization = provider.ensureInitialFeed(boardId: 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(pendingResponses, hasLength(2));

    final signalCompleted = await Future.any<bool>([
      provider.initialFeedFuture.then((_) => true),
      Future<bool>.delayed(const Duration(milliseconds: 30), () => false),
    ]);
    expect(signalCompleted, isFalse);

    pendingResponses[1].complete(
      Response(
        requestOptions: RequestOptions(path: '/posts'),
        statusCode: 200,
        data: {'posts': [], 'total': 0},
      ),
    );
    await Future.wait([oldInitialization, newInitialization]);
    await provider.initialFeedFuture;
  });
}
