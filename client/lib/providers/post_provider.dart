import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../models/post.dart';
import '../services/post_cache_service.dart';
import '../utils/app_feedback.dart';

/// 每个板块的帖子状态
class _BoardState {
  List<Post> posts = [];
  List<Post> pinnedPosts = [];
  String algorithmVersion = '';
  bool isLoading = false;
  String? error;
  int currentPage = 1;
  bool hasMore = true;
  bool hasLoaded = false;
  bool hasCacheLoaded = false;
  String currentSort = 'time';
  String? sessionId;
  int requestVersion = 0;
  int revision = 0;
  DateTime? lastSuccessfulRefreshAt;
  bool isRecoveringExpiredSession = false;
}

/// 创建帖子的返回结果
class CreatePostResult {
  final bool success;
  final String? errorMessage;
  final Post? post;

  const CreatePostResult({
    required this.success,
    this.errorMessage,
    this.post,
  });
}

class DeletePostResult {
  final bool success;
  final String? errorMessage;
  const DeletePostResult({required this.success, this.errorMessage});
}

class PinPostResult {
  final bool success;
  final String? errorMessage;
  final Post? post;

  const PinPostResult({
    required this.success,
    this.errorMessage,
    this.post,
  });
}

@visibleForTesting
Map<String, dynamic> buildPostListParams({
  required int boardId,
  String? type,
  int? tagId,
  required String sort,
  required int page,
  required int loadedCount,
  String? sessionId,
  int limit = 20,
}) {
  final params = <String, dynamic>{
    'board': boardId,
    'type': type,
    'sort': sort,
    'limit': limit,
  };
  if (usesHomeFeedV2(boardId: boardId, sort: sort, type: type, tagId: tagId)) {
    params['feed_version'] = 3;
  }
  params['capabilities'] = 'poll_v1';
  if (tagId != null) {
    params['tag_id'] = tagId;
  }
  final usesSnapshot = sessionId != null && (sort == 'all' || sort == 'hot');
  if (usesSnapshot) {
    params.addAll({
      'scene': 'loadmore',
      'session_id': sessionId,
      'offset': loadedCount,
    });
  } else {
    params['page'] = page;
  }
  return params;
}

@visibleForTesting
bool usesHomeFeedV2(
        {required int boardId,
        required String sort,
        String? type,
        int? tagId}) =>
    boardId == 1 &&
    (sort == 'all' || sort == 'time');

class PostProvider extends ChangeNotifier {
  final Dio _dio;
  final bool _enableCache;

  final Map<String, _BoardState> _boards = {};
  final Map<String, Future<void>> _inflightRequests = {};
  final int _activeBoardId = 1;

  PostProvider(this._dio, {bool enableCache = true})
      : _enableCache = enableCache;

  String _stateKey(int boardId, String sort, String? type, {int? tagId}) {
    return '$boardId|$sort|${type ?? ''}|${tagId ?? ''}';
  }

  String _postsEndpoint(String sort, {String? type}) {
    final hasSectionType = type != null && type.trim().isNotEmpty;
    return sort == 'featured' && !hasSectionType ? '/posts/featured' : '/posts';
  }

  _BoardState _ensureBoard(int boardId,
      {String sort = 'time', String? type, int? tagId}) {
    final key = _stateKey(boardId, sort, type, tagId: tagId);
    return _boards.putIfAbsent(key, () {
      final state = _BoardState();
      state.currentSort = sort;
      return state;
    });
  }

  // ---- 当前活跃板块 ----
  List<Post> get posts => _board.posts;
  bool get isLoading => _board.isLoading;
  String? get error => _board.error;
  bool get hasMore => _board.hasMore;
  bool get hasLoaded => _board.hasLoaded;

  _BoardState get _board => _ensureBoard(_activeBoardId);

  List<Post> postsFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).posts;
  List<Post> pinnedPostsFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).pinnedPosts;
  bool isLoadingFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).isLoading;
  bool hasLoadedFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).hasLoaded;
  bool hasMoreFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).hasMore;

  int requestVersionFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId)
          .requestVersion;

  int revisionFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).revision;

  DateTime? lastSuccessfulRefreshAtFor(
    int boardId, {
    String sort = 'time',
    String? type,
    int? tagId,
  }) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId)
          .lastSuccessfulRefreshAt;

  /// 清除关注信息流缓存，在登录/退出/切换账号/关注/取消关注后调用
  void invalidateFollowingFeed() {
    final keys = _boards.keys.where((key) {
      final parts = key.split('|');
      return parts.length >= 2 && parts[1] == 'following';
    }).toList();

    for (final key in keys) {
      _boards[key]?.requestVersion++;
      _boards.remove(key);
    }

    notifyListeners();
  }

  Future<void> _savePostsToCache(
    int boardId,
    String sort,
    List<Post> posts, {
    String? type,
    int? tagId,
  }) async {
    if (!_enableCache || sort == 'following') return;
    try {
      final board = _boards[_stateKey(boardId, sort, type, tagId: tagId)];
      final algorithmVersion =
          board != null && board.algorithmVersion.isNotEmpty
              ? board.algorithmVersion
              : PostCacheService.expectedAlgorithmVersion(
                  boardId: boardId, sort: sort, type: type, tagId: tagId);
      final feed = CachedPostFeed(
        posts: posts,
        pinnedPosts: board?.pinnedPosts ?? [],
        algorithmVersion: algorithmVersion,
      );
      await PostCacheService.savePosts(
        boardId,
        feed,
        sort: sort,
        type: type,
        tagId: tagId,
      );
    } catch (e) {
      debugPrint('保存帖子缓存失败(board=$boardId, sort=$sort): $e');
    }
  }

  void _upsertPostInBoards(Post post) {
    var touched = false;
    for (final entry in _boards.entries) {
      final keyParts = entry.key.split('|');
      final boardId = int.tryParse(keyParts.first) ?? 0;
      if (boardId != post.boardId) continue;

      final sort = keyParts.length > 1 ? keyParts[1] : 'time';
      final type =
          keyParts.length > 2 && keyParts[2].isNotEmpty ? keyParts[2] : null;
      final tagId = keyParts.length > 3 && keyParts[3].isNotEmpty
          ? int.tryParse(keyParts[3])
          : null;
      if (type != null && type != post.postType) continue;
      if (tagId != null && tagId != post.waterTagId) continue;

      final board = entry.value;
      final index = board.posts.indexWhere((p) => p.id == post.id);
      if (index >= 0) {
        board.posts[index] = post;
      } else if (sort == 'time') {
        board.posts = [post, ...board.posts];
      } else {
        continue;
      }
      board.revision++;
      _savePostsToCache(boardId, sort, board.posts, type: type, tagId: tagId);
      touched = true;
    }
    if (touched) {
      notifyListeners();
    }
  }

  /// SWR 模式：先读缓存秒开 → 后台增量拉取
  Future<void> _loadCachedThenRefresh(
    int boardId, {
    String? type,
    int? tagId,
    String sort = 'time',
  }) async {
    final board = _ensureBoard(boardId, sort: sort, type: type, tagId: tagId);
    if (board.hasCacheLoaded) return;
    board.hasCacheLoaded = true;
    board.currentSort = sort;
    final requestVersion = ++board.requestVersion;

    if (board.posts.isEmpty) {
      board.isLoading = true;
      board.error = null;
      board.revision++;
      notifyListeners();
    }

    CachedPostFeed? cachedFeed;
    // 第一步：极速上屏 — 读本地缓存（关注信息流不使用缓存）
    if (_enableCache && sort != 'following') {
      try {
        cachedFeed = await PostCacheService.loadPosts(
          boardId,
          sort: sort,
          type: type,
          tagId: tagId,
        );
        if (requestVersion != board.requestVersion) return;
        if (cachedFeed != null &&
            cachedFeed.posts.isNotEmpty &&
            cachedFeed.freshness == PostFeedCacheFreshness.fresh) {
          board.posts = cachedFeed.posts;
          if (usesHomeFeedV2(
              boardId: boardId, sort: sort, type: type, tagId: tagId)) {
            board.pinnedPosts = cachedFeed.pinnedPosts;
            board.algorithmVersion = cachedFeed.algorithmVersion;
          }
          board.revision++;
          notifyListeners();
        }
      } catch (_) {}
    }

    bool succeeded = false;

    // 第二步：重新拉取最新第一页，刷新作者头像、图片、统计等完整数据。
    // 只按 since 增量拉取会让旧缓存里的作者资料长期停留在过期状态，
    // 杀后台重启后就容易看到文字头像或旧头像。
    try {
      board.sessionId = null; // 清除老的会话快照
      final params = <String, dynamic>{
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': 1,
        'limit': 20,
        'scene': 'refresh',
      };
      if (usesHomeFeedV2(
          boardId: boardId, sort: sort, type: type, tagId: tagId)) {
        params['feed_version'] = 3;
      }
      params['capabilities'] = 'poll_v1';
      if (tagId != null) {
        params['tag_id'] = tagId;
      }

      final response = await _dio.get(
        _postsEndpoint(sort, type: type),
        queryParameters: params,
      );
      if (requestVersion != board.requestVersion) return;
      if (response.statusCode == 200) {
        succeeded = true;
        final data = response.data;
        if (data['session_id'] != null) {
          board.sessionId = data['session_id'];
        }
        final newPosts = ((data['posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();
        final pinned = ((data['pinned_posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();
        final isHomeV2 = usesHomeFeedV2(
            boardId: boardId, sort: sort, type: type, tagId: tagId);
        if (isHomeV2) {
          board.pinnedPosts = pinned;
          board.algorithmVersion = data['algorithm_version']?.toString() ?? '';
        }

        if (isHomeV2) {
          board.posts = newPosts;
          board.pinnedPosts = pinned;
          await _savePostsToCache(
            boardId,
            sort,
            board.posts,
            type: type,
            tagId: tagId,
          );
        } else if (sort != 'time') {
          board.posts = newPosts;
          await _savePostsToCache(
            boardId,
            sort,
            board.posts,
            type: type,
            tagId: tagId,
          );
        } else if (newPosts.isNotEmpty) {
          // 第四步：增量合并 — 更新已有帖子，插入新帖子
          bool changed = false;
          final existingIndexMap = {
            for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i,
          };
          final uniqueNew = <Post>[];

          for (final np in newPosts) {
            final idx = existingIndexMap[np.id];
            if (idx != null) {
              board.posts[idx] = np; // 更新已有帖子
              changed = true;
            } else {
              uniqueNew.add(np); // 全新帖子
            }
          }

          if (uniqueNew.isNotEmpty) {
            board.posts = [...uniqueNew, ...board.posts];
            changed = true;
          }

          if (changed) {
            // 写回缓存
            await _savePostsToCache(
              boardId,
              sort,
              board.posts,
              type: type,
              tagId: tagId,
            );
          }
        }

        final total = (data['total'] as num?)?.toInt();
        board.hasMore =
            total != null ? board.posts.length < total : newPosts.length >= 20;
        board.currentPage = 2;
      }
    } on DioException catch (e) {
      if (cachedFeed != null &&
          cachedFeed.posts.isNotEmpty &&
          cachedFeed.freshness == PostFeedCacheFreshness.stale) {
        board.posts = cachedFeed.posts;
        if (usesHomeFeedV2(
            boardId: boardId, sort: sort, type: type, tagId: tagId)) {
          board.pinnedPosts = cachedFeed.pinnedPosts;
          board.algorithmVersion = cachedFeed.algorithmVersion;
        }
      }
      debugPrint('增量拉取失败(board=$boardId): ${e.type}');
    } catch (e) {
      if (cachedFeed != null &&
          cachedFeed.posts.isNotEmpty &&
          cachedFeed.freshness == PostFeedCacheFreshness.stale) {
        board.posts = cachedFeed.posts;
        if (usesHomeFeedV2(
            boardId: boardId, sort: sort, type: type, tagId: tagId)) {
          board.pinnedPosts = cachedFeed.pinnedPosts;
          board.algorithmVersion = cachedFeed.algorithmVersion;
        }
      }
      debugPrint('增量拉取异常(board=$boardId)');
    }

    board.hasLoaded = true;
    board.isLoading = false;
    if (succeeded) {
      board.lastSuccessfulRefreshAt = DateTime.now();
    }
    board.revision++;
    notifyListeners();
  }

  /// 加载更多（翻页）
  Future<void> loadPosts({
    int boardId = 1,
    String? type,
    int? tagId,
    String sort = 'time',
  }) {
    final board = _ensureBoard(boardId, sort: sort, type: type, tagId: tagId);
    final page = board.currentPage;
    final key = 'load_${boardId}_${sort}_${type}_${tagId}_$page';

    if (_inflightRequests.containsKey(key)) return _inflightRequests[key]!;

    final future = _loadPostsInternal(
            boardId: boardId, type: type, tagId: tagId, sort: sort)
        .whenComplete(() {
      _inflightRequests.remove(key);
    });
    _inflightRequests[key] = future;
    return future;
  }

  Future<void> _loadPostsInternal({
    int boardId = 1,
    String? type,
    int? tagId,
    String sort = 'time',
  }) async {
    final board = _ensureBoard(boardId, sort: sort, type: type, tagId: tagId);

    // 首次加载走 SWR
    if (!board.hasCacheLoaded) {
      await _loadCachedThenRefresh(boardId,
          type: type, tagId: tagId, sort: sort);
      return;
    }

    if (board.hasLoaded && board.currentSort != sort) {
      await refresh(boardId: boardId, type: type, tagId: tagId, sort: sort);
      return;
    }

    if (board.isLoading || !board.hasMore) return;
    board.isLoading = true;
    board.error = null;
    final requestVersion = board.requestVersion;
    board.revision++;
    notifyListeners();

    try {
      final usesSnapshot =
          board.sessionId != null && (sort == 'all' || sort == 'hot');
      final params = buildPostListParams(
        boardId: boardId,
        type: type,
        tagId: tagId,
        sort: sort,
        page: board.currentPage,
        loadedCount: board.posts.length,
        sessionId: board.sessionId,
      );

      final response = await _dio.get(
        _postsEndpoint(sort, type: type),
        queryParameters: params,
      );
      if (requestVersion != board.requestVersion) return;
      if (response.statusCode == 200) {
        final data = response.data;
        if (data['session_id'] != null) {
          board.sessionId = data['session_id'];
        }
        final newPosts = ((data['posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();

        if (board.currentPage == 1) {
          board.posts = newPosts;
        } else {
          final existingIndexMap = {
            for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i,
          };
          for (final np in newPosts) {
            final idx = existingIndexMap[np.id];
            if (idx != null) {
              board.posts[idx] = np; // 更新已存在的帖子（比如有评论数更新）
            } else {
              board.posts.add(np); // 尾部追加新帖子
            }
          }
        }

        final total = (data['total'] as num?)?.toInt();
        board.hasMore =
            total != null ? board.posts.length < total : newPosts.length >= 20;
        if (!usesSnapshot) {
          board.currentPage++;
        }
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      final isFeedSessionExpired = e.response?.statusCode == 409 &&
          data is Map &&
          data['code']?.toString() == 'feed_session_expired';

      if (isFeedSessionExpired &&
          usesHomeFeedV2(
              boardId: boardId, sort: sort, type: type, tagId: tagId)) {
        if (!board.isRecoveringExpiredSession) {
          board.isRecoveringExpiredSession = true;
          board.sessionId = null;
          board.error = null;
          board.isLoading = false;
          try {
            await _refreshInternal(
              boardId: boardId,
              type: type,
              tagId: tagId,
              sort: sort,
            );
          } finally {
            board.isRecoveringExpiredSession = false;
          }
          return;
        }
      }
      board.error = AppFeedback.dioErrorMessage(e);
    } catch (e) {
      board.error = e.toString();
    }

    if (requestVersion == board.requestVersion) {
      board.isLoading = false;
      board.hasLoaded = true;
      board.revision++;
      notifyListeners();
    }
  }

  Future<void> refresh({
    int boardId = 1,
    String? type,
    int? tagId,
    String sort = 'time',
  }) {
    final key = 'refresh_${boardId}_${sort}_${type}_$tagId';

    if (_inflightRequests.containsKey(key)) return _inflightRequests[key]!;

    final future =
        _refreshInternal(boardId: boardId, type: type, tagId: tagId, sort: sort)
            .whenComplete(() {
      _inflightRequests.remove(key);
    });
    _inflightRequests[key] = future;
    return future;
  }

  Future<void> _refreshInternal({
    int boardId = 1,
    String? type,
    int? tagId,
    String sort = 'time',
  }) async {
    final board = _ensureBoard(boardId, sort: sort, type: type, tagId: tagId);
    final requestVersion = ++board.requestVersion;
    board.currentSort = sort;
    board.currentPage = 1;
    board.hasMore = true;
    board.hasCacheLoaded = true;

    if (board.posts.isEmpty) {
      board.isLoading = true;
      board.revision++;
      notifyListeners();
    }

    bool succeeded = false;

    try {
      board.sessionId = null; // 清除老的会话快照
      final useHomeFeedV2 = usesHomeFeedV2(
          boardId: boardId, sort: sort, type: type, tagId: tagId);
      final params = <String, dynamic>{
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': 1,
        'limit': 20,
        'scene': 'refresh',
      };
      if (useHomeFeedV2) {
        params['feed_version'] = 3;
      }
      params['capabilities'] = 'poll_v1';
      if (tagId != null) {
        params['tag_id'] = tagId;
      }

      final response = await _dio.get(
        _postsEndpoint(sort, type: type),
        queryParameters: params,
      );
      if (requestVersion != board.requestVersion) return;
      if (response.statusCode == 200) {
        board.sessionId = response.data['session_id']?.toString();
        final newPosts = ((response.data['posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();

        if (useHomeFeedV2) {
          final pinned = ((response.data['pinned_posts'] as List?) ?? [])
              .map((e) => Post.fromJson(e))
              .toList();
          board.pinnedPosts = pinned;
          board.algorithmVersion =
              response.data['algorithm_version']?.toString() ?? '';
        }

        // 当用户主动刷新或切换排序时，由于后端返回的是全新的一页完整数据，
        // 我们必须完全覆写当前列表，绝不能执行在原地更新旧帖的合并逻辑，
        // 否则将导致已存在的帖子依然呆在旧的索引位置，造成视觉上排序无效。
        board.posts = newPosts;
        await _savePostsToCache(
          boardId,
          sort,
          board.posts,
          type: type,
          tagId: tagId,
        );

        final total = (response.data['total'] as num?)?.toInt();
        board.hasMore =
            total != null ? newPosts.length < total : newPosts.length >= 20;
        board.currentPage = 2;
        succeeded = true;
      }
    } on DioException catch (e) {
      debugPrint('刷新失败(board=$boardId): ${e.message}');
    }

    if (requestVersion == board.requestVersion) {
      board.isLoading = false;
      board.hasLoaded = true;
      if (succeeded) {
        board.lastSuccessfulRefreshAt = DateTime.now();
      }
      board.revision++;
      notifyListeners();
    }
  }

  Future<List<Post>> searchPosts({
    int boardId = 1,
    String? type,
    String sort = 'time',
    required String query,
    int limit = 50,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    try {
      final response = await _dio.get(
        '/posts',
        queryParameters: {
          'board': boardId,
          'type': type,
          'sort': sort,
          'page': 1,
          'limit': limit,
          'q': trimmed,
          'capabilities': 'poll_v1',
        },
      );

      if (response.statusCode == 200) {
        final data = response.data;
        return ((data['posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();
      }
    } on DioException catch (e) {
      debugPrint('搜索帖子失败: ${AppFeedback.dioErrorMessage(e)}');
    } catch (e) {
      debugPrint('搜索帖子失败: $e');
    }
    return [];
  }

  // ---- 以下为原有方法，保持不变 ----

  Future<CreatePostResult> createPost({
    required int boardId,
    required String content,
    String? title,
    String? postType,
    int? waterTagId,
    double? price,
    String? contactType,
    String? contact,
    List<int>? fileIds,
    List<String>? marketTags,
    int? teamNeededCount,
    List<String>? teamRoles,
    DateTime? teamDeadline,
  }) async {
    try {
      final formData = FormData.fromMap({
        'board_id': boardId,
        'content': content,
        if (title != null && title.isNotEmpty) 'title': title,
        if (postType != null) 'post_type': postType,
        if (waterTagId != null && waterTagId > 0) 'water_tag_id': waterTagId,
        if (price != null) 'price': price,
        if (contactType != null && contactType.isNotEmpty)
          'contact_type': contactType,
        if (contact != null && contact.isNotEmpty) 'contact': contact,
        if (fileIds != null && fileIds.isNotEmpty)
          'file_ids': fileIds.join(','),
        if (marketTags != null && marketTags.isNotEmpty)
          'market_tags': marketTags.join(','),
        if (teamNeededCount != null) 'team_needed_count': teamNeededCount,
        if (teamRoles != null) 'team_roles_json': jsonEncode(teamRoles),
        if (teamDeadline != null)
          'team_deadline': teamDeadline.toUtc().toIso8601String(),
      });

      final response = await _dio.post('/posts', data: formData);
      if (response.statusCode == 201) {
        final created = response.data is Map<String, dynamic>
            ? Post.fromJson(response.data as Map<String, dynamic>)
            : null;
        if (created != null) {
          _upsertPostInBoards(created);
        }
        return CreatePostResult(success: true, post: created);
      }
      return CreatePostResult(
        success: false,
        errorMessage: '发布失败 (${response.statusCode})',
      );
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '发布失败');
      return CreatePostResult(success: false, errorMessage: msg);
    } catch (e) {
      return CreatePostResult(success: false, errorMessage: '创建帖子失败: $e');
    }
  }

  Future<CreatePostResult> updatePost({
    required int postId,
    required int boardId,
    required String content,
    String? title,
    String? postType,
    int? waterTagId,
    double? price,
    String? contactType,
    String? contact,
    List<int>? fileIds,
    List<String>? marketTags,
    int? teamNeededCount,
    List<String>? teamRoles,
    DateTime? teamDeadline,
    bool sendTeamFields = false,
    bool sendWaterTagField = false,
  }) async {
    try {
      final formData = FormData.fromMap({
        'board_id': boardId,
        'content': content,
        'title': title ?? '',
        'post_type': postType ?? '',
        'price': price ?? 0,
        'contact_type': contactType ?? '',
        'contact': contact ?? '',
        if (sendWaterTagField) 'water_tag_id': waterTagId ?? 0,
        if (!sendWaterTagField && waterTagId != null && waterTagId > 0)
          'water_tag_id': waterTagId,
        'file_ids': fileIds?.join(',') ?? '',
        'market_tags': marketTags?.join(',') ?? '',
        if (sendTeamFields) 'team_needed_count': teamNeededCount ?? 0,
        if (sendTeamFields)
          'team_roles_json': jsonEncode(teamRoles ?? const <String>[]),
        if (sendTeamFields)
          'team_deadline': teamDeadline?.toUtc().toIso8601String() ?? '',
      });

      final response = await _dio.put('/posts/$postId', data: formData);
      if (response.statusCode == 200) {
        final updated = Post.fromJson(response.data as Map<String, dynamic>);
        _replacePostInBoards(updated);
        notifyListeners();
        return CreatePostResult(success: true, post: updated);
      }
      return CreatePostResult(
        success: false,
        errorMessage: '更新失败 (${response.statusCode})',
      );
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '更新失败');
      return CreatePostResult(success: false, errorMessage: msg);
    } catch (e) {
      return CreatePostResult(success: false, errorMessage: '更新帖子失败: $e');
    }
  }

  Future<Post?> updatePostStatus({
    required int postId,
    required String status,
  }) async {
    try {
      final response = await _dio.patch(
        '/posts/$postId/status',
        data: {'status': status},
      );
      if (response.statusCode == 200 && response.data != null) {
        final updated = Post.fromJson(response.data as Map<String, dynamic>);
        _replacePostInBoards(updated);
        notifyListeners();
        return updated;
      }
    } on DioException catch (e) {
      debugPrint('更新帖子状态失败: ${AppFeedback.dioErrorMessage(e)}');
    } catch (e) {
      debugPrint('更新帖子状态失败: $e');
    }
    return null;
  }

  Future<int?> uploadImage(XFile file) async {
    try {
      final bytes = await file.readAsBytes();
      final rawName = file.name.trim().isNotEmpty
          ? file.name.trim()
          : file.path.split('/').last;
      final filename = _safeUploadFilename(rawName);

      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
        ),
      });

      final response = await _dio.post('/upload', data: formData);
      if (response.statusCode == 200 && response.data != null) {
        return response.data['file_id'] as int?;
      }
    } catch (e) {
      debugPrint('上传图片失败: $e');
    }
    return null;
  }

  String _safeUploadFilename(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif')) {
      return name;
    }
    return 'upload_${DateTime.now().millisecondsSinceEpoch}.jpg';
  }

  Future<DeletePostResult> deletePostDetailed(int postId) async {
    try {
      final response = await _dio.delete('/posts/$postId');
      if (response.statusCode == 200) {
        bool changedAny = false;
        for (final board in _boards.values) {
          final beforeLen = board.posts.length;
          board.posts.removeWhere((p) => p.id == postId);
          if (board.posts.length != beforeLen) {
            board.revision++;
            changedAny = true;
          }
        }
        if (changedAny) {
          notifyListeners();
        }
        return const DeletePostResult(success: true);
      }
      return DeletePostResult(
        success: false,
        errorMessage: '删除失败 (${response.statusCode})',
      );
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '删除帖子失败');
      return DeletePostResult(success: false, errorMessage: msg);
    } catch (e) {
      final msg = '删除帖子失败: $e';
      return DeletePostResult(success: false, errorMessage: msg);
    }
  }

  Future<bool> deletePost(int postId) async {
    final result = await deletePostDetailed(postId);
    return result.success;
  }

  Future<DeletePostResult> deleteReplyDetailed(int replyId) async {
    try {
      final response = await _dio.delete('/replies/$replyId');
      if (response.statusCode == 200) {
        return const DeletePostResult(success: true);
      }
      return DeletePostResult(
        success: false,
        errorMessage: '删除失败 (${response.statusCode})',
      );
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '删除评论失败');
      return DeletePostResult(success: false, errorMessage: msg);
    } catch (e) {
      final msg = '删除评论失败: $e';
      return DeletePostResult(success: false, errorMessage: msg);
    }
  }

  Future<bool> deleteReply(int replyId) async {
    final result = await deleteReplyDetailed(replyId);
    return result.success;
  }

  Future<PinPostResult> pinPost({
    required int postId,
    required DateTime pinnedUntil,
    int pinnedWeight = 50,
    String reason = '',
  }) async {
    try {
      final response = await _dio.post(
        '/admin/posts/$postId/pin',
        data: {
          'pinned_until': pinnedUntil.toUtc().toIso8601String(),
          'pinned_weight': pinnedWeight,
          'reason': reason,
        },
      );

      if (response.statusCode == 200) {
        final updated = Post.fromJson(response.data as Map<String, dynamic>);
        _replacePostInBoards(updated);
        notifyListeners();
        return PinPostResult(success: true, post: updated);
      }
      return PinPostResult(
        success: false,
        errorMessage: '置顶失败 (${response.statusCode})',
      );
    } on DioException catch (e) {
      return PinPostResult(
        success: false,
        errorMessage: AppFeedback.dioErrorMessage(e, fallback: '置顶失败'),
      );
    } catch (e) {
      return PinPostResult(success: false, errorMessage: '置顶失败: $e');
    }
  }

  Future<PinPostResult> unpinPost(int postId) async {
    try {
      final response = await _dio.post('/admin/posts/$postId/unpin');

      if (response.statusCode == 200) {
        final updated = Post.fromJson(response.data as Map<String, dynamic>);
        _replacePostInBoards(updated);
        notifyListeners();
        return PinPostResult(success: true, post: updated);
      }
      return PinPostResult(
        success: false,
        errorMessage: '取消置顶失败 (${response.statusCode})',
      );
    } on DioException catch (e) {
      return PinPostResult(
        success: false,
        errorMessage: AppFeedback.dioErrorMessage(e, fallback: '取消置顶失败'),
      );
    } catch (e) {
      return PinPostResult(success: false, errorMessage: '取消置顶失败: $e');
    }
  }

  Future<void> refreshHomePinnedFeeds({bool refreshFeatured = false}) async {
    final futures = <Future<void>>[
      refresh(boardId: 1, sort: 'all'),
      refresh(boardId: 1, sort: 'time'),
    ];
    if (refreshFeatured) {
      futures.add(refresh(boardId: 1, sort: 'featured'));
    }
    await Future.wait(futures);
  }

  Future<void> refreshWaterSectionFeeds(String sectionSlug) async {
    if (sectionSlug.trim().isEmpty) return;
    await Future.wait([
      refresh(boardId: 1, type: sectionSlug, sort: 'all'),
      refresh(boardId: 1, type: sectionSlug, sort: 'time'),
      refresh(boardId: 1, type: sectionSlug, sort: 'featured'),
    ]);
  }

  /// 刷新指定标签的组队信息流，用于状态变化后重新排序。
  Future<void> refreshTeamTagFeeds({
    required int tagId,
    required String postType,
  }) async {
    await refresh(
      boardId: 1,
      type: postType,
      tagId: tagId,
      sort: 'all',
    );
  }

  Future<bool> likePost(int postId) async {
    try {
      await _dio.post('/posts/$postId/like');
      return true;
    } catch (e) {
      debugPrint('点赞失败: $e');
      return false;
    }
  }

  Future<bool> unlikePost(int postId) async {
    try {
      await _dio.delete('/posts/$postId/like');
      return true;
    } catch (e) {
      debugPrint('取消点赞失败: $e');
      return false;
    }
  }

  /// 供外部在获取到最新帖子数据（如浏览量增加）时更新本地缓存，保持内外一致
  void updatePostInCache(Post updated) {
    applyExternalPostUpdate(updated);
  }

  /// 接收投票等独立业务返回的最新 Post，只替换已有项而不改变列表排序。
  void applyExternalPostUpdate(Post updated) {
    _replacePostInBoards(updated);
    notifyListeners();
  }

  /// 从全部已加载列表和置顶区移除帖子，并同步持久化缓存。
  void removeExternalPost(int postId) {
    var changed = false;
    for (final entry in _boards.entries) {
      final keyParts = entry.key.split('|');
      final boardId = int.tryParse(keyParts.first) ?? 0;
      final sort = keyParts.length > 1 ? keyParts[1] : 'time';
      final type =
          keyParts.length > 2 && keyParts[2].isNotEmpty ? keyParts[2] : null;
      final tagId = keyParts.length > 3 && keyParts[3].isNotEmpty
          ? int.tryParse(keyParts[3])
          : null;
      final board = entry.value;
      final beforePosts = board.posts.length;
      final beforePinned = board.pinnedPosts.length;
      board.posts.removeWhere((post) => post.id == postId);
      board.pinnedPosts.removeWhere((post) => post.id == postId);
      if (beforePosts != board.posts.length ||
          beforePinned != board.pinnedPosts.length) {
        board.revision++;
        changed = true;
        _savePostsToCache(boardId, sort, board.posts, type: type, tagId: tagId);
      }
    }
    if (changed) notifyListeners();
  }

  void _replacePostInBoards(Post updated) {
    for (final entry in _boards.entries) {
      final keyParts = entry.key.split('|');
      final boardId = int.tryParse(keyParts.first) ?? 0;
      final sort = keyParts.length > 1 ? keyParts[1] : 'time';
      final type =
          keyParts.length > 2 && keyParts[2].isNotEmpty ? keyParts[2] : null;
      final tagId = keyParts.length > 3 && keyParts[3].isNotEmpty
          ? int.tryParse(keyParts[3])
          : null;
      final board = entry.value;
      final index = board.posts.indexWhere((p) => p.id == updated.id);
      if (index >= 0) {
        board.posts[index] = updated;
        board.revision++;
        // 同步持久化到本地缓存，防止杀后台后数据(如浏览量)倒退
        _savePostsToCache(boardId, sort, board.posts, type: type, tagId: tagId);
      }
      final pinnedIndex =
          board.pinnedPosts.indexWhere((p) => p.id == updated.id);
      if (pinnedIndex >= 0) {
        board.pinnedPosts[pinnedIndex] = updated;
        board.revision++;
        _savePostsToCache(boardId, sort, board.posts, type: type, tagId: tagId);
      }
    }
  }
}
