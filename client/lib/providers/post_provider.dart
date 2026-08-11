import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import '../config/api_constants.dart';
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

/// 一次可见性变更中被移除的帖子快照（FEED-3 撤销用）。
class _FeedRemovedEntry {
  _FeedRemovedEntry({
    required this.boardKey,
    required this.post,
    required this.originalIndex,
    required this.revisionAtMutation,
  });

  final String boardKey;
  final Post post;
  final int originalIndex;
  // 记录变更提交后该 board 的 revision，用于撤销时的 revision 安全检查。
  int revisionAtMutation;
}

/// 可见性变更（不感兴趣 / 不看TA）的撤销记录，用于 Snackbar「撤销」。
class FeedVisibilityUndo {
  const FeedVisibilityUndo._({
    required this.isAuthorHide,
    required this.postId,
    required this.authorId,
    required List<_FeedRemovedEntry> removed,
  }) : _removed = removed;

  final bool isAuthorHide;
  final int postId;
  final int authorId;
  final List<_FeedRemovedEntry> _removed;
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
bool usesHomeFeedV2({
  required int boardId,
  required String sort,
  String? type,
  int? tagId,
}) {
  final normalizedType = type?.trim() ?? '';
  return boardId == 1 &&
      normalizedType.isEmpty &&
      tagId == null &&
      (sort == 'all' || sort == 'time');
}

/// 乐观点赞变更的结果。
enum LikeMutationStatus {
  /// 服务端确认成功，乐观状态已生效。
  success,

  /// 网络失败，已回滚到变更前快照。
  failed,

  /// 服务端返回明确状态冲突，已按服务端 reconcile 结果收敛。
  conflict,

  /// 同一帖子已有变更在途，本次调用未发起任何请求。
  pending,
}

class LikeMutationResult {
  const LikeMutationResult.success({
    required this.originalPost,
    required this.optimisticPost,
  })  : status = LikeMutationStatus.success,
        reconciledPost = null;

  const LikeMutationResult.failed({
    required this.originalPost,
    required this.optimisticPost,
  })  : status = LikeMutationStatus.failed,
        reconciledPost = null;

  const LikeMutationResult.conflict({
    required this.originalPost,
    required this.optimisticPost,
    required this.reconciledPost,
  }) : status = LikeMutationStatus.conflict;

  const LikeMutationResult.pending()
      : status = LikeMutationStatus.pending,
        originalPost = null,
        optimisticPost = null,
        reconciledPost = null;

  final LikeMutationStatus status;

  /// 调用时传入的帖子快照（失败时用于恢复视图）。
  final Post? originalPost;

  /// 乐观应用后的副本（成功时用于同步视图）。
  final Post? optimisticPost;

  /// 冲突 reconcile 得到的服务端状态（冲突时优先使用）。
  final Post? reconciledPost;
}

/// 后台新鲜度探测结果：只暂存，不覆写可见列表。
class FreshnessProbeResult {
  const FreshnessProbeResult({
    required this.posts,
    required this.pinnedPosts,
    required this.algorithmVersion,
    required this.newPostCount,
    required this.fetchedAt,
  });

  final List<Post> posts;
  final List<Post> pinnedPosts;
  final String algorithmVersion;

  /// 相对当前可见列表，第一页新增的帖子数量（仅“最新”信息流可信）。
  final int newPostCount;
  final DateTime fetchedAt;
}

class PostProvider extends ChangeNotifier {
  final Dio _dio;
  final bool _enableCache;

  final Map<String, _BoardState> _boards = {};
  final Map<String, Future<void>> _inflightRequests = {};
  final Map<int, Post> _canonicalPosts = {};
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
      {String sort = 'time', String? type, int? tagId}) {
    final posts =
        _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).posts;
    for (final post in posts) {
      _canonicalPosts[post.id] = post;
    }
    return posts;
  }

  List<Post> pinnedPostsFor(int boardId,
      {String sort = 'time', String? type, int? tagId}) {
    final posts =
        _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).pinnedPosts;
    for (final post in posts) {
      _canonicalPosts[post.id] = post;
    }
    return posts;
  }

  /// 返回当前已加载帖子状态，供卡片避免维护第二份点赞快照。
  Post? postFor(int postId) => _canonicalPosts[postId];
  bool isLoadingFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).isLoading;
  bool hasLoadedFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).hasLoaded;
  bool hasMoreFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).hasMore;

  /// 读取指定信息流的错误，不与当前活跃 sort 混用。
  String? errorFor(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _ensureBoard(boardId, sort: sort, type: type, tagId: tagId).error;

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

  /// 清除首页 Feed 缓存与状态（H1.5：账号隔离）。
  ///
  /// 首页（board 1）内容可能受 UserHiddenAuthor / not_interested 个性化影响，
  /// 因此登录 / 退出 / 切换账号 / 隐藏或恢复作者后必须整体失效，避免账号 A 的
  /// 个性化缓存被账号 B 读到。同时 bump requestVersion，丢弃在途旧请求的写入。
  Future<void> invalidateHomeFeedCaches() async {
    final keys = _boards.keys.where((key) => key.startsWith('1|')).toList();
    for (final key in keys) {
      _boards[key]?.requestVersion++;
      _boards.remove(key);
    }
    if (_enableCache) {
      try {
        await PostCacheService.clearBoard(1);
      } catch (e) {
        debugPrint('清除首页 Feed 缓存失败: $e');
      }
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
      board.error = AppFeedback.dioErrorMessage(e);
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
      board.error = e.toString();
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
    board.error = null;

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
      board.error = AppFeedback.dioErrorMessage(e);
      debugPrint('刷新失败(board=$boardId): ${e.message}');
    } catch (e) {
      board.error = e.toString();
      debugPrint('刷新异常(board=$boardId): $e');
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

  /// 上传图片，返回 file_id。
  ///
  /// [onProgress] 提供 (sent, total)。优先用 `MultipartFile.fromFile` 流式上传，
  /// 避免整文件 `readAsBytes` 占用内存；Web/无路径时回退 bytes。
  Future<int?> uploadImage(
    XFile file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      final rawName = file.name.trim().isNotEmpty
          ? file.name.trim()
          : file.path.split('/').last;
      final filename = _safeUploadFilename(rawName);

      final MultipartFile multipartFile;
      final path = file.path;
      final pathUsable = path.isNotEmpty &&
          !path.startsWith('blob:') &&
          await File(path).exists();
      if (pathUsable) {
        multipartFile = await MultipartFile.fromFile(path, filename: filename);
      } else {
        final bytes = await file.readAsBytes();
        multipartFile = MultipartFile.fromBytes(bytes, filename: filename);
      }

      final formData = FormData.fromMap({'file': multipartFile});

      final response = await _dio.post(
        '/upload',
        data: formData,
        onSendProgress: onProgress,
      );
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

  // ---- 统一乐观点赞状态机 ----
  // Feed 卡片、详情页共用同一套 mutation，禁止各 Widget 各自维护第二份点赞状态。

  final Set<int> _pendingLikePostIds = {};

  /// 该帖子是否已有一次点赞变更在途（防连点）。
  bool isLikePending(int postId) => _pendingLikePostIds.contains(postId);

  /// 对帖子执行一次乐观点赞/取消点赞。
  ///
  /// 立即翻转 [post] 的点赞状态并同步到所有已加载信息流，然后请求服务端；
  /// 网络失败回滚旧快照；服务端明确状态冲突时通过单次 GET 做 reconcile，
  /// 以服务端状态为准（不做整页重新拉取）。
  Future<LikeMutationResult> toggleLikeOptimistic(Post post) async {
    final postId = post.id;
    if (_pendingLikePostIds.contains(postId)) {
      return const LikeMutationResult.pending();
    }
    _pendingLikePostIds.add(postId);

    final targetLiked = !post.isLiked;
    final optimistic = post.copyWith(
      isLiked: targetLiked,
      likeCount: (post.likeCount + (targetLiked ? 1 : -1)).clamp(0, 1 << 30),
    );
    _replacePostInBoards(optimistic);
    notifyListeners();

    try {
      if (targetLiked) {
        await _dio.post('/posts/$postId/like');
      } else {
        await _dio.delete('/posts/$postId/like');
      }
      return LikeMutationResult.success(
        originalPost: post,
        optimisticPost: optimistic,
      );
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final data = e.response?.data;
      final isExplicitConflict = statusCode != null &&
          statusCode >= 400 &&
          statusCode < 500 &&
          data is Map &&
          data['error'] != null;
      if (isExplicitConflict) {
        // 服务端明确拒绝（例如“已经点赞/未点赞”）：单次 REST reconcile，
        // 用服务端状态覆盖，而不是盲目回滚成本地旧快照。
        final reconciled = await _reconcilePost(postId);
        if (reconciled != null) {
          _replacePostInBoards(reconciled);
          notifyListeners();
          return LikeMutationResult.conflict(
            originalPost: post,
            optimisticPost: optimistic,
            reconciledPost: reconciled,
          );
        }
      }
      // 网络错误或 reconcile 失败：回滚旧快照。
      _replacePostInBoards(post);
      notifyListeners();
      return LikeMutationResult.failed(
        originalPost: post,
        optimisticPost: optimistic,
      );
    } catch (e) {
      _replacePostInBoards(post);
      notifyListeners();
      return LikeMutationResult.failed(
        originalPost: post,
        optimisticPost: optimistic,
      );
    } finally {
      _pendingLikePostIds.remove(postId);
    }
  }

  Future<Post?> _reconcilePost(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId');
      if (response.statusCode != 200 || response.data is! Map) return null;
      return Post.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      debugPrint('点赞冲突 reconcile 失败: $e');
      return null;
    }
  }

  // ---- 后台新鲜度探测 ----
  // 自动刷新只做“探测 + 暂存”，绝不直接覆写用户正在阅读的可见列表；
  // 是否应用由页面（顶部温和更新 / “内容有更新”浮条）决定。

  final Map<String, FreshnessProbeResult> _pendingFreshSnapshots = {};
  final Map<String, Future<FreshnessProbeResult?>> _probeInflight = {};

  /// 是否有尚未应用的探测快照（供页面显示“内容有更新”浮条）。
  bool hasPendingFreshSnapshot(int boardId,
          {String sort = 'time', String? type, int? tagId}) =>
      _pendingFreshSnapshots.containsKey(
        _stateKey(boardId, sort, type, tagId: tagId),
      );

  /// 拉取第一页做新鲜度探测：列表内容不变时返回 null，变化时暂存快照并返回。
  ///
  /// 探测受 [requestVersion] 保护：期间用户手动刷新或切换了信息流，
  /// 过期响应会被丢弃，不会污染新列表。
  Future<FreshnessProbeResult?> probeFreshness({
    int boardId = 1,
    String sort = 'time',
    String? type,
    int? tagId,
  }) {
    final key = _stateKey(boardId, sort, type, tagId: tagId);
    final reqKey = 'probe_$key';
    final inflight = _probeInflight[reqKey];
    if (inflight != null) return inflight;

    final future = _probeInternal(
      boardId: boardId,
      sort: sort,
      type: type,
      tagId: tagId,
    );
    _probeInflight[reqKey] = future;
    return future.whenComplete(() {
      if (_probeInflight[reqKey] == future) {
        _probeInflight.remove(reqKey);
      }
    });
  }

  Future<FreshnessProbeResult?> _probeInternal({
    required int boardId,
    required String sort,
    String? type,
    int? tagId,
  }) async {
    final board = _ensureBoard(boardId, sort: sort, type: type, tagId: tagId);
    final requestVersion = board.requestVersion;
    try {
      final params = <String, dynamic>{
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': 1,
        'limit': 20,
        'scene': 'refresh',
        'capabilities': 'poll_v1',
      };
      if (usesHomeFeedV2(
          boardId: boardId, sort: sort, type: type, tagId: tagId)) {
        params['feed_version'] = 3;
      }
      if (tagId != null) {
        params['tag_id'] = tagId;
      }
      final response = await _dio.get(
        _postsEndpoint(sort, type: type),
        queryParameters: params,
      );
      if (requestVersion != board.requestVersion) return null;
      if (response.statusCode != 200) return null;

      final posts = ((response.data['posts'] as List?) ?? [])
          .map((e) => Post.fromJson(e))
          .toList();
      final pinned = ((response.data['pinned_posts'] as List?) ?? [])
          .map((e) => Post.fromJson(e))
          .toList();
      final algorithmVersion =
          response.data['algorithm_version']?.toString() ?? '';

      final currentIds = board.posts.take(20).map((p) => p.id).toSet();
      final newIds = posts.take(20).map((p) => p.id).toSet();
      final pinnedChanged = !setEquals(
        board.pinnedPosts.map((p) => p.id).toSet(),
        pinned.map((p) => p.id).toSet(),
      );
      final hasChanges = !setEquals(currentIds, newIds) || pinnedChanged;
      if (!hasChanges) return null;

      final result = FreshnessProbeResult(
        posts: posts,
        pinnedPosts: pinned,
        algorithmVersion: algorithmVersion,
        newPostCount: newIds.difference(currentIds).length,
        fetchedAt: DateTime.now(),
      );
      _pendingFreshSnapshots[_stateKey(boardId, sort, type, tagId: tagId)] =
          result;
      return result;
    } catch (e) {
      debugPrint('新鲜度探测失败(board=$boardId, sort=$sort): $e');
      return null;
    }
  }

  /// 应用暂存的新快照（用户点击“内容有更新”后调用）。
  ///
  /// 覆盖列表并同步持久化缓存；滚动回顶由调用方负责。
  Future<bool> applyPendingFreshSnapshot({
    int boardId = 1,
    String sort = 'time',
    String? type,
    int? tagId,
  }) async {
    final key = _stateKey(boardId, sort, type, tagId: tagId);
    final pending = _pendingFreshSnapshots.remove(key);
    if (pending == null) return false;

    final board = _ensureBoard(boardId, sort: sort, type: type, tagId: tagId);
    board.posts = pending.posts;
    board.pinnedPosts = pending.pinnedPosts;
    board.algorithmVersion = pending.algorithmVersion;
    board.sessionId = null;
    board.currentPage = 2;
    board.hasMore = pending.posts.length >= 20;
    board.lastSuccessfulRefreshAt = pending.fetchedAt;
    board.revision++;
    await _savePostsToCache(
      boardId,
      sort,
      board.posts,
      type: type,
      tagId: tagId,
    );
    notifyListeners();
    return true;
  }

  /// 丢弃暂存快照（切换信息流或页面销毁时调用，避免陈旧快照被误应用）。
  void clearPendingFreshSnapshot({
    int boardId = 1,
    String sort = 'time',
    String? type,
    int? tagId,
  }) {
    _pendingFreshSnapshots.remove(_stateKey(boardId, sort, type, tagId: tagId));
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
    _canonicalPosts.remove(postId);
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
    _canonicalPosts[updated.id] = updated;
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

  // ── FEED-3 乐观可见性 ─────────────────────────────────────────────

  /// 是否属于首页主 Tab（sort ∈ all/time/featured/following 且无版块 type）。
  bool _isMainFeedBoard(String key) {
    final parts = key.split('|');
    if (parts.length < 3) return false;
    final sort = parts[1];
    final type = parts[2];
    if (type.isNotEmpty) return false;
    return sort == 'all' ||
        sort == 'time' ||
        sort == 'featured' ||
        sort == 'following';
  }

  void _syncBoardCacheAfterMutation(String key, _BoardState board) {
    if (!_enableCache) return;
    final keyParts = key.split('|');
    final boardId = int.tryParse(keyParts.first) ?? 0;
    final sort = keyParts.length > 1 ? keyParts[1] : 'time';
    final type =
        keyParts.length > 2 && keyParts[2].isNotEmpty ? keyParts[2] : null;
    final tagId = keyParts.length > 3 && keyParts[3].isNotEmpty
        ? int.tryParse(keyParts[3])
        : null;
    _savePostsToCache(boardId, sort, board.posts, type: type, tagId: tagId);
  }

  void _restoreRemoved(List<_FeedRemovedEntry> removed) {
    for (final entry in removed) {
      final board = _boards[entry.boardKey];
      if (board == null) continue;
      final index = entry.originalIndex.clamp(0, board.posts.length);
      board.posts.insert(index, entry.post);
      _canonicalPosts[entry.post.id] = entry.post;
      board.revision++;
    }
  }

  /// 乐观「不感兴趣」：本地立即从 all 信息流移除该帖，成功后返回撤销记录；
  /// 服务端失败则回滚。source 为用户点击时所在 Tab（仅用于分析）。
  Future<FeedVisibilityUndo?> markPostNotInterestedOptimistic(
    Post post, {
    required String source,
  }) async {
    final removed = <_FeedRemovedEntry>[];
    for (final entry in _boards.entries) {
      if (!_isMainFeedBoard(entry.key) || entry.key.split('|')[1] != 'all') {
        continue;
      }
      final board = entry.value;
      final index = board.posts.indexWhere((p) => p.id == post.id);
      if (index < 0) continue;
      final removedPost = board.posts[index];
      board.posts.removeAt(index);
      board.revision++;
      removed.add(_FeedRemovedEntry(
        boardKey: entry.key,
        post: removedPost,
        originalIndex: index,
        revisionAtMutation: board.revision,
      ));
      _syncBoardCacheAfterMutation(entry.key, board);
    }
    if (removed.isNotEmpty) notifyListeners();

    try {
      await _dio.put(
        ApiConstants.feedNotInterestedPath(post.id),
        queryParameters: {'source': source},
      );
    } catch (_) {
      _restoreRemoved(removed);
      if (removed.isNotEmpty) notifyListeners();
      return null;
    }
    return FeedVisibilityUndo._(
      isAuthorHide: false,
      postId: post.id,
      authorId: 0,
      removed: removed,
    );
  }

  /// 乐观「不看 TA」：本地立即从 all/time/featured/following 移除该作者全部帖子。
  Future<FeedVisibilityUndo?> hideAuthorOptimistic(int authorId) async {
    final removed = <_FeedRemovedEntry>[];
    for (final entry in _boards.entries) {
      if (!_isMainFeedBoard(entry.key)) continue;
      final board = entry.value;
      final boardRemoved = <_FeedRemovedEntry>[];
      for (var i = board.posts.length - 1; i >= 0; i--) {
        if (board.posts[i].authorId == authorId) {
          boardRemoved.add(_FeedRemovedEntry(
            boardKey: entry.key,
            post: board.posts[i],
            originalIndex: i,
            revisionAtMutation: board.revision,
          ));
          board.posts.removeAt(i);
        }
      }
      if (boardRemoved.isNotEmpty) {
        board.revision++;
        // 撤销的 revision 基准取变更提交后的 board revision。
        for (final e in boardRemoved) {
          e.revisionAtMutation = board.revision;
        }
        removed.addAll(boardRemoved);
        _syncBoardCacheAfterMutation(entry.key, board);
      }
    }
    if (removed.isNotEmpty) notifyListeners();

    try {
      await _dio.put(ApiConstants.feedHiddenAuthorPath(authorId));
    } catch (_) {
      _restoreRemoved(removed);
      if (removed.isNotEmpty) notifyListeners();
      return null;
    }
    return FeedVisibilityUndo._(
      isAuthorHide: true,
      postId: 0,
      authorId: authorId,
      removed: removed,
    );
  }

  /// 撤销一次可见性变更（Snackbar「撤销」）。
  ///
  /// Revision 安全：仅当相关 board 的 revision 与变更时一致才原位插回；
  /// 若期间 Feed 已刷新（revision 变化），只调 API 撤销、不插回旧数据，
  /// 由下一次刷新与服务端对齐。
  Future<bool> undoFeedVisibility(FeedVisibilityUndo undo) async {
    try {
      if (undo.isAuthorHide) {
        await _dio.delete(ApiConstants.feedHiddenAuthorPath(undo.authorId));
      } else {
        await _dio.delete(ApiConstants.feedNotInterestedPath(undo.postId));
      }
    } catch (_) {
      // API 撤销失败时保持当前隐藏状态，避免 UI 与服务端语义相反。
      return false;
    }

    final allSame = undo._removed.every((entry) {
      final board = _boards[entry.boardKey];
      return board != null && board.revision == entry.revisionAtMutation;
    });
    if (!allSame) return true;

    _restoreRemoved(undo._removed);
    for (final entry in undo._removed) {
      final board = _boards[entry.boardKey];
      if (board != null) _syncBoardCacheAfterMutation(entry.boardKey, board);
    }
    notifyListeners();
    return true;
  }
}
