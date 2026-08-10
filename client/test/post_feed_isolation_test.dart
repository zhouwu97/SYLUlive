import 'dart:async';
import 'dart:convert';
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

Map<String, dynamic> _marketPostJson(
  int id, {
  List<String> marketTags = const [],
}) {
  return {
    ..._postJson(id),
    'title': '显示器',
    'content': '成色很好',
    'board_id': 2,
    'post_type': 'sell',
    'price': 99,
    'market_tags': marketTags,
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

  test('section featured feeds use the post list endpoint', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(_response(options, requests.length));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    await provider.refresh(
      boardId: 1,
      sort: 'featured',
      type: 'course_study',
    );
    await provider.refresh(boardId: 1, sort: 'featured');

    expect(requests[0].path, '/posts');
    expect(requests[0].queryParameters['type'], 'course_study');
    expect(requests[1].path, '/posts/featured');
    expect(requests[1].queryParameters['type'], isNull);
  });

  test('invalidateFollowingFeed clears every following feed state', () async {
    final dio = Dio();
    var requestCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestCount++;
          handler.resolve(_response(options, requestCount));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    await provider.refresh(boardId: 1, sort: 'following');
    await provider.refresh(
      boardId: 1,
      sort: 'following',
      type: 'course_study',
    );
    await provider.refresh(
      boardId: 1,
      sort: 'following',
      type: 'campus_life',
      tagId: 3,
    );
    await provider.refresh(boardId: 1, sort: 'all', type: 'course_study');

    provider.invalidateFollowingFeed();

    expect(provider.postsFor(1, sort: 'following'), isEmpty);
    expect(
      provider.postsFor(1, sort: 'following', type: 'course_study'),
      isEmpty,
    );
    expect(
      provider.postsFor(
        1,
        sort: 'following',
        type: 'campus_life',
        tagId: 3,
      ),
      isEmpty,
    );
    expect(provider.hasLoadedFor(1, sort: 'following'), isFalse);
    expect(
      provider.hasLoadedFor(1, sort: 'following', type: 'course_study'),
      isFalse,
    );
    expect(
      provider.postsFor(1, sort: 'all', type: 'course_study').single.id,
      4,
    );
    expect(
      provider.hasLoadedFor(1, sort: 'all', type: 'course_study'),
      isTrue,
    );
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
      CachedPostFeed(posts: [
        Post(
          id: 1,
          content: 'cached',
          boardId: 99,
          authorId: oldAuthor.id,
          author: oldAuthor,
          createdAt: DateTime.utc(2026, 6, 14, 8),
        ),
      ]),
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

  test('post cache excludes account identifiers and invalidates schema 2',
      () async {
    final author = User(
      id: 7,
      studentId: '20260007',
      nickname: '缓存作者',
      creditScore: 88,
      role: 'admin',
      reportCount: 3,
      createdAt: DateTime.utc(2026, 6, 14),
    );
    await PostCacheService.savePosts(
      777,
      CachedPostFeed(
        posts: [
          Post(
            id: 1,
            content: 'cached',
            boardId: 777,
            authorId: author.id,
            author: author,
            createdAt: DateTime.utc(2026, 6, 14, 8),
          ),
        ],
      ),
    );

    final box = await Hive.openBox<String>('post_cache');
    final stored =
        jsonDecode(box.get('board_777_time__')!) as Map<String, dynamic>;
    final cachedAuthor = ((stored['posts'] as List).single
        as Map<String, dynamic>)['author'] as Map<String, dynamic>;
    expect(stored['schema_version'], 6);
    expect(cachedAuthor.containsKey('student_id'), isFalse);
    expect(cachedAuthor['credit_score'], 88);
    expect(cachedAuthor.containsKey('report_count'), isFalse);
    expect(cachedAuthor['id'], author.id);

    await box.put(
      'board_778_time__',
      jsonEncode({
        'schema_version': 3,
        'algorithm_version': PostCacheService.expectedAlgorithmVersion(
          boardId: 778,
          sort: 'time',
        ),
        'saved_at': DateTime.now().toUtc().toIso8601String(),
        'pinned_posts': const [],
        'posts': const [],
      }),
    );

    expect(await PostCacheService.loadPosts(778), isNull);
    expect(box.containsKey('board_778_time__'), isFalse);
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

  test('invalidateHomeFeedCaches clears board-1 state and cache only', () async {
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(
        posts: [
          Post(
            id: 1,
            title: '首页帖',
            content: '首页',
            boardId: 1,
            authorId: 1,
            createdAt: DateTime.utc(2026, 6, 14, 8),
          ),
        ],
        algorithmVersion: PostCacheService.expectedAlgorithmVersion(
            boardId: 1, sort: 'all'),
      ),
      sort: 'all',
    );
    await PostCacheService.savePosts(
      2,
      CachedPostFeed(
        posts: [
          Post(
            id: 2,
            title: '集市帖',
            content: '集市',
            boardId: 2,
            authorId: 1,
            createdAt: DateTime.utc(2026, 6, 14, 8),
          ),
        ],
      ),
      sort: 'all',
    );

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) =>
            handler.resolve(_response(options, 1)),
      ),
    );
    final provider = PostProvider(dio);
    await provider.loadPosts(boardId: 1, sort: 'all');
    await provider.loadPosts(boardId: 2, sort: 'all');
    expect(provider.postsFor(1, sort: 'all'), isNotEmpty);
    expect(provider.postsFor(2, sort: 'all'), isNotEmpty);

    await provider.invalidateHomeFeedCaches();

    expect(provider.postsFor(1, sort: 'all'), isEmpty, reason: 'board 1 状态已清');
    expect(provider.postsFor(2, sort: 'all'), isNotEmpty, reason: '仅失效首页 board 1');
    expect(await PostCacheService.loadPosts(1, sort: 'all'), isNull,
        reason: 'board 1 Hive 缓存已清');
    expect(await PostCacheService.loadPosts(2, sort: 'all'), isNotNull,
        reason: 'board 2 Hive 缓存保留');
  });

  test('invalidateHomeFeedCaches drops in-flight stale board-1 responses',
      () async {
    final dio = Dio();
    final gate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          await gate.future;
          handler.resolve(_response(options, 10));
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    final loading = provider.refresh(boardId: 1, sort: 'all');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // 账号切换 → 失效首页 Feed；在途旧请求不得写回新账号状态。
    await provider.invalidateHomeFeedCaches();
    gate.complete();
    await loading;

    expect(provider.postsFor(1, sort: 'all'), isEmpty,
        reason: '在途旧请求不得写回失效后的状态');
  });

  test('post parses market tags from list and comma-separated strings', () {
    final fromList = Post.fromJson({
      'id': 1,
      'content': 'content',
      'board_id': 2,
      'author_id': 1,
      'market_tags': ['自提', '可小刀'],
      'created_at': '2026-06-14T08:00:00Z',
    });
    expect(fromList.marketTags, ['自提', '可小刀']);

    final fromString = Post.fromJson({
      'id': 2,
      'content': 'content',
      'board_id': 2,
      'author_id': 1,
      'market_tags': '自提,急出',
      'created_at': '2026-06-14T08:00:00Z',
    });
    expect(fromString.marketTags, ['自提', '急出']);
  });

  test('createPost sends selected market tags as independent form data',
      () async {
    final dio = Dio();
    String? sentTags;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final formData = options.data as FormData;
          sentTags = formData.fields
              .firstWhere((field) => field.key == 'market_tags')
              .value;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 201,
              data: _postJson(1),
            ),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    final result = await provider.createPost(
      boardId: 2,
      content: '成色很好',
      title: '显示器',
      postType: 'sell',
      marketTags: ['自提', '可小刀'],
    );

    expect(result.success, isTrue);
    expect(sentTags, '自提,可小刀');
  });

  test('createPost exposes returned post with selected market tags', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 201,
              data: _marketPostJson(9, marketTags: ['自提']),
            ),
          );
        },
      ),
    );
    final provider = PostProvider(dio, enableCache: false);

    final result = await provider.createPost(
      boardId: 2,
      content: '成色很好',
      title: '显示器',
      postType: 'sell',
      marketTags: ['自提'],
    );

    expect(result.success, isTrue);
    expect(result.post?.marketTags, ['自提']);
  });

  test('post cache preserves pin and featured metadata', () async {
    final pinnedUntil = DateTime.utc(2026, 6, 17);
    await PostCacheService.savePosts(
      88,
      CachedPostFeed(
          posts: [
            Post(
              id: 8,
              content: 'cached',
              boardId: 88,
              authorId: 1,
              createdAt: DateTime.utc(2026, 6, 14, 8),
              replyCount: 3,
              likeCount: 4,
              isPinned: true,
              pinnedUntil: pinnedUntil,
              pinnedWeight: 70,
              isFeatured: true,
              featuredBy: 2,
            ),
          ],
          algorithmVersion: PostCacheService.expectedAlgorithmVersion(
              boardId: 88, sort: 'all')),
      sort: 'all',
    );

    final loaded = await PostCacheService.loadPosts(88, sort: 'all');
    expect(loaded?.posts.single.replyCount, 3);
    expect(loaded?.posts.single.likeCount, 4);
    expect(loaded?.posts.single.isPinned, isTrue);
    expect(loaded?.posts.single.pinnedUntil, pinnedUntil);
    expect(loaded?.posts.single.pinnedWeight, 70);
    expect(loaded?.posts.single.isFeatured, isTrue);
    expect(loaded?.posts.single.featuredBy, 2);
  });

  test('post cache isolates water section and tag feeds', () async {
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [
        Post(
          id: 1,
          title: 'course_title',
          content: 'course',
          boardId: 1,
          authorId: 1,
          postType: 'course_study',
          createdAt: DateTime.utc(2026, 6, 14, 8),
        ),
      ]),
      type: 'course_study',
    );

    await PostCacheService.savePosts(
      1,
      CachedPostFeed(
          posts: [
            Post(
              id: 2,
              title: 'campus_title',
              content: 'campus',
              boardId: 1,
              authorId: 1,
              postType: 'campus_life',
              createdAt: DateTime.utc(2026, 6, 14, 8),
            ),
          ],
          algorithmVersion: PostCacheService.expectedAlgorithmVersion(
              boardId: 1, sort: 'all', type: 'campus_life', tagId: 3)),
      sort: 'all',
      type: 'campus_life',
      tagId: 3,
    );

    final course = await PostCacheService.loadPosts(
      1,
      sort: 'time',
      type: 'course_study',
    );
    final campus = await PostCacheService.loadPosts(
      1,
      sort: 'all',
      type: 'campus_life',
      tagId: 3,
    );
    final unrelated = await PostCacheService.loadPosts(
      1,
      sort: 'all',
      type: 'campus_life',
    );

    expect(course?.posts.single.content, 'course');
    expect(campus?.posts.single.content, 'campus');
    expect(unrelated, isNull);
  });

  test(
      'post cache automatically populates missing algorithm version and applies strict version isolation',
      () async {
    // 1. 空 algorithmVersion 保存时自动补全 (首页 all -> home_all_v2)
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [
        Post(
            id: 1,
            content: 't1',
            boardId: 1,
            authorId: 1,
            createdAt: DateTime.now()),
      ], algorithmVersion: ''), // deliberately empty
      sort: 'all',
    );
    final homeAll = await PostCacheService.loadPosts(1, sort: 'all');
    expect(homeAll?.algorithmVersion, PostCacheService.homeAllAlgorithmVersion);

    // 2. 首页 time -> home_time_v2
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [
        Post(
            id: 2,
            content: 't2',
            boardId: 1,
            authorId: 1,
            createdAt: DateTime.now()),
      ], algorithmVersion: ''), // deliberately empty
      sort: 'time',
    );
    final homeTime = await PostCacheService.loadPosts(1, sort: 'time');
    expect(
        homeTime?.algorithmVersion, PostCacheService.homeTimeAlgorithmVersion);

    // 3. 专题 all -> feed_v1
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [
        Post(
            id: 3,
            content: 't3',
            boardId: 1,
            authorId: 1,
            createdAt: DateTime.now()),
      ], algorithmVersion: ''), // deliberately empty
      sort: 'all',
      type: 'campus_life',
    );
    final sectionAll =
        await PostCacheService.loadPosts(1, sort: 'all', type: 'campus_life');
    expect(sectionAll?.algorithmVersion,
        PostCacheService.fallbackAlgorithmVersion);

    // 4. 集市 all -> feed_v1
    await PostCacheService.savePosts(
      2, // boardId 2 is market
      CachedPostFeed(posts: [
        Post(
            id: 4,
            content: 't4',
            boardId: 2,
            authorId: 1,
            createdAt: DateTime.now()),
      ], algorithmVersion: ''), // deliberately empty
      sort: 'all',
    );
    final marketAll = await PostCacheService.loadPosts(2, sort: 'all');
    expect(
        marketAll?.algorithmVersion, PostCacheService.fallbackAlgorithmVersion);

    // 5. 算法版本不匹配时删除缓存
    // First, save a valid cache
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [
        Post(
            id: 5,
            content: 't5',
            boardId: 1,
            authorId: 1,
            createdAt: DateTime.now()),
      ], algorithmVersion: 'some_malicious_version_or_v1_instead_of_v2'),
      sort: 'all',
    );
    final mismatch = await PostCacheService.loadPosts(1, sort: 'all');
    expect(mismatch, isNull);
  });

  test('post cache preserves water section metadata', () async {
    await PostCacheService.savePosts(
      1,
      CachedPostFeed(posts: [
        Post(
          id: 1,
          content: 'course',
          boardId: 1,
          authorId: 1,
          postType: 'course_study',
          waterSectionPinned: true,
          waterSectionPinId: 100,
          waterSectionFeatured: true,
          waterSectionFeaturedId: 200,
          waterSectionAuthorMeta: WaterSectionAuthorMeta(
            sectionId: 1,
            sectionSlug: 'course_study',
            sectionTitle: '课程学习',
            level: 3,
            exp: 150,
            title: '常驻同学',
          ),
          createdAt: DateTime.utc(2026, 6, 14, 8),
        ),
      ]),
      type: 'course_study',
    );

    final loaded = await PostCacheService.loadPosts(
      1,
      sort: 'time',
      type: 'course_study',
    );
    final post = loaded!.posts.single;

    expect(post.waterSectionPinned, isTrue);
    expect(post.waterSectionPinId, 100);
    expect(post.waterSectionFeatured, isTrue);
    expect(post.waterSectionFeaturedId, 200);
    expect(post.waterSectionAuthorMeta?.sectionSlug, 'course_study');
    expect(post.waterSectionAuthorMeta?.level, 3);
    expect(post.waterSectionAuthorMeta?.title, '常驻同学');
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

  test('post section pin and featured state are parsed correctly', () {
    final post = Post.fromJson({
      'id': 1,
      'content': 'content',
      'board_id': 1,
      'author_id': 1,
      'is_pinned': false,
      'water_section_pinned': true,
      'water_section_pin_id': 100,
      'is_featured': false,
      'water_section_featured': true,
      'water_section_featured_id': 200,
      'created_at': '2026-06-14T08:00:00Z',
    });

    expect(post.isActivePinned,
        isFalse); // Section pin does not make it globally active pinned
    expect(post.waterSectionPinned, isTrue);
    expect(post.waterSectionPinId, 100);
    expect(post.isFeatured, isFalse);
    expect(post.waterSectionFeatured, isTrue);
    expect(post.waterSectionFeaturedId, 200);
  });

  test('post parses exp awards and home featured pending state', () {
    final post = Post.fromJson({
      'id': 1,
      'content': 'content',
      'board_id': 1,
      'author_id': 1,
      'home_featured_pending': true,
      'exp_awards': [
        {
          'scope': 'global',
          'exp': 10,
          'action': 'post_daily',
          'level_before': 2,
          'level_after': 2,
        },
        {
          'scope': 'water_section',
          'exp': 10,
          'action': 'post_daily',
          'level_before': 2,
          'level_after': 3,
          'level_up': true,
          'section_title': '校园生活',
          'title_after': '常驻同学',
        },
      ],
      'created_at': '2026-06-14T08:00:00Z',
    });

    expect(post.homeFeaturedPending, isTrue);
    expect(post.expAwards, hasLength(2));
    expect(post.expAwards.last.scope, 'water_section');
    expect(post.expAwards.last.levelUp, isTrue);
    expect(post.expAwards.last.titleAfter, '常驻同学');
  });

  test('feed_version=2 is sent and pinnedPosts are updated during V2 refresh',
      () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'posts': [_postJson(1)],
              'pinned_posts': [_postJson(2)],
              'algorithm_version': 'home_all_v2',
              'total': 1,
            },
          ));
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.refresh(boardId: 1, sort: 'all');

    expect(requests.length, 1);
    expect(requests.first.queryParameters['feed_version'], 3);
    expect(provider.pinnedPostsFor(1, sort: 'all').length, 1);
    expect(provider.pinnedPostsFor(1, sort: 'all').first.id, 2);
  });

  test('409 session expired triggers automatic recovery', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          if (options.queryParameters['scene'] == 'loadmore') {
            handler.reject(DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 409,
                data: {'code': 'feed_session_expired'},
              ),
            ));
            return;
          }
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'posts': [_postJson(requests.length)],
              'total': 50,
              'session_id': 'sess-1',
            },
          ));
        },
      ),
    );

    final provider = PostProvider(dio, enableCache: false);
    await provider.refresh(boardId: 1, sort: 'all');
    expect(requests.length, 1);

    await provider.loadPosts(boardId: 1, sort: 'all');

    // Request 1: refresh
    // Request 2: loadmore -> 409
    // Request 3: refresh (recovery)
    expect(requests.length, 3);
    expect(requests[1].queryParameters['scene'], 'loadmore');
    expect(requests[2].queryParameters['scene'], 'refresh');
    expect(provider.error, isNull);
    expect(provider.postsFor(1, sort: 'all').first.id, 3);
  });

  test(
      'clearLegacyCache removes schema 3, empty string, and corrupt json but keeps schema 6',
      () async {
    final box = await Hive.openBox<String>('post_cache');

    // Insert corrupt json
    await box.put('corrupt', '{corrupt: true');

    // Insert empty string
    await box.put('empty', '');

    // Insert schema 3 data
    await box.put(
        'schema3',
        jsonEncode({
          'schema_version': 3,
          'algorithm_version': 'home_all_v2',
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'posts': [],
        }));

    // Insert valid schema 6 data
    await box.put(
      'schema6',
        jsonEncode({
          'schema_version': 6,
          'algorithm_version': 'home_time_v2',
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'posts': [],
        }));

    final deletedCount = await PostCacheService.clearLegacyCache();

    expect(deletedCount, 3);
    expect(box.get('corrupt'), isNull);
    expect(box.get('empty'), isNull);
    expect(box.get('schema3'), isNull);
    expect(box.get('schema6'), isNotNull);
  });
}
