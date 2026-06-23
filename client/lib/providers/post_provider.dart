import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'dart:io';
import '../models/post.dart';
import '../services/post_cache_service.dart';
import '../utils/app_feedback.dart';

/// 每个板块的帖子状态
class _BoardState {
  List<Post> posts = [];
  bool isLoading = false;
  String? error;
  int currentPage = 1;
  bool hasMore = true;
  bool hasLoaded = false;
  bool hasCacheLoaded = false;
  String currentSort = 'time';
  String? sessionId;
  int requestVersion = 0;
}

/// 创建帖子的返回结果
class CreatePostResult {
  final bool success;
  final String? errorMessage;
  const CreatePostResult({required this.success, this.errorMessage});
}

class DeletePostResult {
  final bool success;
  final String? errorMessage;
  const DeletePostResult({required this.success, this.errorMessage});
}

@visibleForTesting
Map<String, dynamic> buildPostListParams({
  required int boardId,
  String? type,
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

class PostProvider extends ChangeNotifier {
  final Dio _dio;
  final bool _enableCache;

  final Map<String, _BoardState> _boards = {};
  final int _activeBoardId = 1;

  PostProvider(this._dio, {bool enableCache = true})
      : _enableCache = enableCache;

  String _stateKey(int boardId, String sort, String? type) {
    return '$boardId|$sort|${type ?? ''}';
  }

  _BoardState _ensureBoard(
    int boardId, {
    String sort = 'time',
    String? type,
  }) {
    final key = _stateKey(boardId, sort, type);
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

  List<Post> postsFor(
    int boardId, {
    String sort = 'time',
    String? type,
  }) =>
      _ensureBoard(boardId, sort: sort, type: type).posts;
  bool isLoadingFor(
    int boardId, {
    String sort = 'time',
    String? type,
  }) =>
      _ensureBoard(boardId, sort: sort, type: type).isLoading;
  bool hasLoadedFor(
    int boardId, {
    String sort = 'time',
    String? type,
  }) =>
      _ensureBoard(boardId, sort: sort, type: type).hasLoaded;
  bool hasMoreFor(
    int boardId, {
    String sort = 'time',
    String? type,
  }) =>
      _ensureBoard(boardId, sort: sort, type: type).hasMore;

  int requestVersionFor(
    int boardId, {
    String sort = 'time',
    String? type,
  }) =>
      _ensureBoard(boardId, sort: sort, type: type).requestVersion;

  Future<void> _savePostsToCache(
    int boardId,
    String sort,
    List<Post> posts,
  ) async {
    if (!_enableCache) return;
    try {
      await PostCacheService.savePosts(boardId, posts, sort: sort);
    } catch (e) {
      debugPrint('保存帖子缓存失败(board=$boardId, sort=$sort): $e');
    }
  }

  /// SWR 模式：先读缓存秒开 → 后台增量拉取
  Future<void> _loadCachedThenRefresh(int boardId,
      {String? type, String sort = 'time'}) async {
    final board = _ensureBoard(boardId, sort: sort, type: type);
    if (board.hasCacheLoaded) return;
    board.hasCacheLoaded = true;
    board.currentSort = sort;
    final requestVersion = ++board.requestVersion;

    // 第一步：极速上屏 — 读本地缓存
    if (_enableCache) {
      try {
        final cached = await PostCacheService.loadPosts(boardId, sort: sort);
        if (requestVersion != board.requestVersion) return;
        if (cached.isNotEmpty) {
          board.posts = cached;
          notifyListeners();
        }
      } catch (_) {}
    }

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

      final response = await _dio.get('/posts', queryParameters: params);
      if (requestVersion != board.requestVersion) return;
      if (response.statusCode == 200) {
        final data = response.data;
        if (data['session_id'] != null) {
          board.sessionId = data['session_id'];
        }
        final newPosts = ((data['posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();

        if (sort != 'time') {
          board.posts = newPosts;
          await _savePostsToCache(boardId, sort, board.posts);
        } else if (newPosts.isNotEmpty) {
          // 第四步：增量合并 — 更新已有帖子，插入新帖子
          bool changed = false;
          final existingIndexMap = {
            for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i
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
            await _savePostsToCache(boardId, sort, board.posts);
          }
        }

        final total = (data['total'] as num?)?.toInt();
        board.hasMore =
            total != null ? board.posts.length < total : newPosts.length >= 20;
        board.currentPage = 2;
      }
    } on DioException catch (e) {
      // 网络失败时，缓存已上屏，静默忽略
      debugPrint('增量拉取失败(board=$boardId): ${e.message}');
    } catch (e) {
      debugPrint('增量拉取异常(board=$boardId): $e');
    }

    board.hasLoaded = true;
    notifyListeners();
  }

  /// 加载更多（翻页）
  Future<void> loadPosts(
      {int boardId = 1, String? type, String sort = 'time'}) async {
    final board = _ensureBoard(boardId, sort: sort, type: type);

    // 首次加载走 SWR
    if (!board.hasCacheLoaded) {
      await _loadCachedThenRefresh(boardId, type: type, sort: sort);
      return;
    }

    if (board.hasLoaded && board.currentSort != sort) {
      await refresh(boardId: boardId, type: type, sort: sort);
      return;
    }

    if (board.isLoading || !board.hasMore) return;
    board.isLoading = true;
    board.error = null;
    final requestVersion = board.requestVersion;
    notifyListeners();

    try {
      final usesSnapshot =
          board.sessionId != null && (sort == 'all' || sort == 'hot');
      final params = buildPostListParams(
        boardId: boardId,
        type: type,
        sort: sort,
        page: board.currentPage,
        loadedCount: board.posts.length,
        sessionId: board.sessionId,
      );

      final response = await _dio.get('/posts', queryParameters: params);
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
            for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i
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
      board.error = AppFeedback.dioErrorMessage(e);
    } catch (e) {
      board.error = e.toString();
    }

    if (requestVersion == board.requestVersion) {
      board.isLoading = false;
      board.hasLoaded = true;
      notifyListeners();
    }
  }

  Future<void> refresh(
      {int boardId = 1, String? type, String sort = 'time'}) async {
    final board = _ensureBoard(boardId, sort: sort, type: type);
    final requestVersion = ++board.requestVersion;
    board.currentSort = sort;
    board.currentPage = 1;
    board.hasMore = true;

    if (board.posts.isEmpty) {
      board.isLoading = true;
      notifyListeners();
    }

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

      final response = await _dio.get('/posts', queryParameters: params);
      if (requestVersion != board.requestVersion) return;
      if (response.statusCode == 200) {
        board.sessionId = response.data['session_id']?.toString();
        final newPosts = ((response.data['posts'] as List?) ?? [])
            .map((e) => Post.fromJson(e))
            .toList();

        // 当用户主动刷新或切换排序时，由于后端返回的是全新的一页完整数据，
        // 我们必须完全覆写当前列表，绝不能执行在原地更新旧帖的合并逻辑，
        // 否则将导致已存在的帖子依然呆在旧的索引位置，造成视觉上排序无效。
        board.posts = newPosts;
        await _savePostsToCache(boardId, sort, board.posts);

        final total = (response.data['total'] as num?)?.toInt();
        board.hasMore =
            total != null ? newPosts.length < total : newPosts.length >= 20;
        board.currentPage = 2;
      }
    } on DioException catch (e) {
      debugPrint('刷新失败(board=$boardId): ${e.message}');
    }

    if (requestVersion == board.requestVersion) {
      board.isLoading = false;
      board.hasLoaded = true;
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
      final response = await _dio.get('/posts', queryParameters: {
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': 1,
        'limit': limit,
        'q': trimmed,
      });

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
    double? price,
    String? contact,
    List<int>? fileIds,
  }) async {
    try {
      final formData = FormData.fromMap({
        'board_id': boardId,
        'content': content,
        if (title != null && title.isNotEmpty) 'title': title,
        if (postType != null) 'post_type': postType,
        if (price != null) 'price': price,
        if (contact != null && contact.isNotEmpty) 'contact': contact,
        if (fileIds != null && fileIds.isNotEmpty)
          'file_ids': fileIds.join(','),
      });

      final response = await _dio.post('/posts', data: formData);
      if (response.statusCode == 201) {
        return const CreatePostResult(success: true);
      }
      return CreatePostResult(
          success: false, errorMessage: '发布失败 (${response.statusCode})');
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
    double? price,
    String? contact,
    List<int>? fileIds,
  }) async {
    try {
      final formData = FormData.fromMap({
        'board_id': boardId,
        'content': content,
        'title': title ?? '',
        'post_type': postType ?? '',
        'price': price ?? 0,
        'contact': contact ?? '',
        'file_ids': fileIds?.join(',') ?? '',
      });

      final response = await _dio.put('/posts/$postId', data: formData);
      if (response.statusCode == 200) {
        final updated = Post.fromJson(response.data as Map<String, dynamic>);
        _replacePostInBoards(updated);
        notifyListeners();
        return const CreatePostResult(success: true);
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

  Future<int?> uploadImage(String filePath) async {
    try {
      String uploadPath = filePath;
      if (filePath.startsWith('content://')) {
        final tempDir = Directory.systemTemp;
        final tempFile = File(
            '${tempDir.path}/upload_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await File(filePath).copy(tempFile.path);
        uploadPath = tempFile.path;
      }
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(uploadPath),
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

  Future<DeletePostResult> deletePostDetailed(int postId) async {
    try {
      final response = await _dio.delete('/posts/$postId');
      if (response.statusCode == 200) {
        for (final board in _boards.values) {
          board.posts.removeWhere((p) => p.id == postId);
        }
        notifyListeners();
        return const DeletePostResult(success: true);
      }
      return DeletePostResult(
          success: false, errorMessage: '删除失败 (${response.statusCode})');
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
          success: false, errorMessage: '删除失败 (${response.statusCode})');
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
    _replacePostInBoards(updated);
    notifyListeners();
  }

  void _replacePostInBoards(Post updated) {
    for (final entry in _boards.entries) {
      final keyParts = entry.key.split('|');
      final boardId = int.tryParse(keyParts.first) ?? 0;
      final sort = keyParts.length > 1 ? keyParts[1] : 'time';
      final board = entry.value;
      final index = board.posts.indexWhere((p) => p.id == updated.id);
      if (index >= 0) {
        board.posts[index] = updated;
        // 同步持久化到本地缓存，防止杀后台后数据(如浏览量)倒退
        _savePostsToCache(boardId, sort, board.posts);
      }
    }
  }
}
