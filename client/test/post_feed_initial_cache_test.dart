import 'dart:async';
import 'dart:convert';
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

Response<dynamic> _feedResponse(
  RequestOptions options, {
  required int firstPostId,
  required String sessionId,
  required bool hasMore,
}) {
  return Response(
    requestOptions: options,
    statusCode: 200,
    data: {
      'posts': List.generate(20, (index) => _postJson(firstPostId + index)),
      'total': 60,
      'has_more': hasMore,
      'session_id': sessionId,
    },
  );
}

Future<void> _markCacheStale(String sort) async {
  final box = Hive.box<String>('post_cache');
  final key = box.keys.firstWhere(
    (value) => value.toString().startsWith('board_1_${sort}_'),
  );
  final raw = box.get(key);
  final decoded = jsonDecode(raw!) as Map<String, dynamic>;
  decoded['saved_at'] = DateTime.now()
      .subtract(const Duration(minutes: 11))
      .toUtc()
      .toIso8601String();
  await box.put(key, jsonEncode(decoded));
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

  test('all 首页首屏后分页使用稳定 session 和连续 offset，并追加结果', () async {
    final requests = <RequestOptions>[];
    var requestIndex = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final response = _feedResponse(
            options,
            firstPostId: requestIndex * 20 + 1,
            sessionId: 'all-session',
            hasMore: true,
          );
          requestIndex++;
          handler.resolve(response);
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.ensureInitialFeed(boardId: 1, sort: 'all');
    await provider.loadPosts(boardId: 1, sort: 'all');
    await provider.loadPosts(boardId: 1, sort: 'all');

    expect(requests, hasLength(3));
    expect(requests[1].queryParameters['scene'], 'loadmore');
    expect(requests[1].queryParameters['session_id'], 'all-session');
    expect(requests[1].queryParameters['offset'], 20);
    expect(requests[2].queryParameters['offset'], 40);
    final posts = provider.postsFor(1, sort: 'all');
    expect(posts, hasLength(60));
    expect(posts.first.id, 1);
    expect(posts[39].id, 40);
  });

  test('time 首页首屏后第一次分页直接请求 page=2', () async {
    final requests = <RequestOptions>[];
    var requestIndex = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final response = _feedResponse(
            options,
            firstPostId: requestIndex * 20 + 1,
            sessionId: 'time-session',
            hasMore: true,
          );
          requestIndex++;
          handler.resolve(response);
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.ensureInitialFeed(boardId: 1, sort: 'time');
    await provider.loadPosts(boardId: 1, sort: 'time');
    await provider.loadPosts(boardId: 1, sort: 'time');

    expect(requests, hasLength(3));
    expect(requests[1].queryParameters['scene'], isNull);
    expect(requests[1].queryParameters['page'], 2);
    expect(requests[2].queryParameters['page'], 3);
    expect(provider.postsFor(1, sort: 'time'), hasLength(60));
    expect(provider.postsFor(1, sort: 'time').first.id, 1);
  });

  test('stale 缓存不会在正常网络响应前作为首页正文展示', () async {
    final stalePost = Post.fromJson(_postJson(701, title: 'stale'));
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [stalePost]),
      sort: 'all',
      sessionEpoch: PostCacheService.activeSessionEpoch,
    );
    await PostCacheService.waitForPendingWrites();
    await _markCacheStale('all');

    final responseCompleter = Completer<Response<dynamic>>();
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          handler.resolve(await responseCompleter.future);
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: true);
    final loading = provider.ensureInitialFeed(boardId: 1, sort: 'all');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.postsFor(1, sort: 'all'), isEmpty);

    responseCompleter.complete(_feedResponse(
      RequestOptions(path: '/posts'),
      firstPostId: 801,
      sessionId: 'fresh-session',
      hasMore: false,
    ));
    await loading;

    expect(provider.postsFor(1, sort: 'all').first.id, 801);
    expect(
      provider.postsFor(1, sort: 'all').any((post) => post.id == stalePost.id),
      isFalse,
    );
  });

  test('fresh 缓存正常刷新后仍可从下一页继续追加', () async {
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [Post.fromJson(_postJson(900, title: 'cached'))]),
      sort: 'all',
      sessionEpoch: PostCacheService.activeSessionEpoch,
    );
    await PostCacheService.waitForPendingWrites();

    final requests = <RequestOptions>[];
    var requestIndex = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final response = _feedResponse(
            options,
            firstPostId: requestIndex == 0 ? 901 : 921,
            sessionId: 'fresh-session',
            hasMore: true,
          );
          requestIndex++;
          handler.resolve(response);
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: true);
    await provider.ensureInitialFeed(boardId: 1, sort: 'all');
    await provider.loadPosts(boardId: 1, sort: 'all');

    expect(requests, hasLength(2));
    expect(requests[1].queryParameters['offset'], 20);
    expect(provider.postsFor(1, sort: 'all'), hasLength(40));
    expect(provider.postsFor(1, sort: 'all').first.id, 901);
  });

  test('服务端 has_more=false 后不再触发无意义分页', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(_feedResponse(
            options,
            firstPostId: 1001,
            sessionId: 'finished-session',
            hasMore: false,
          ));
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.ensureInitialFeed(boardId: 1, sort: 'all');
    await provider.loadPosts(boardId: 1, sort: 'all');

    expect(requests, hasLength(1));
    expect(provider.postsFor(1, sort: 'all'), hasLength(20));
  });

  test('stale 缓存只在网络失败时作为降级内容恢复', () async {
    final stalePost = Post.fromJson(_postJson(702, title: 'stale'));
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [stalePost]),
      sort: 'all',
      sessionEpoch: PostCacheService.activeSessionEpoch,
    );
    await PostCacheService.waitForPendingWrites();
    await _markCacheStale('all');

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: true);
    await provider.ensureInitialFeed(boardId: 1, sort: 'all');

    expect(provider.postsFor(1, sort: 'all').single.id, 702);
    expect(provider.isLoadingFor(1, sort: 'all'), isFalse);
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
