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

class PostProvider extends ChangeNotifier {
  final Dio _dio;

  final Map<int, _BoardState> _boards = {};
  final int _activeBoardId = 1;

  PostProvider(this._dio) {
    _boards[1] = _BoardState();
    _boards[2] = _BoardState();
    _boards[3] = _BoardState();
    _boards[4] = _BoardState();
    // 启动后异步加载缓存（首页优先）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCachedThenRefresh(1, sort: 'time');
    });
  }

  _BoardState _ensureBoard(int boardId) {
    return _boards.putIfAbsent(boardId, _BoardState.new);
  }

  // ---- 当前活跃板块 ----
  List<Post> get posts => _board.posts;
  bool get isLoading => _board.isLoading;
  String? get error => _board.error;
  bool get hasMore => _board.hasMore;
  bool get hasLoaded => _board.hasLoaded;

  _BoardState get _board => _boards[_activeBoardId]!;

  List<Post> postsFor(int boardId) => _boards[boardId]?.posts ?? [];
  bool isLoadingFor(int boardId) => _boards[boardId]?.isLoading ?? false;
  bool hasLoadedFor(int boardId) => _boards[boardId]?.hasLoaded ?? false;

  /// SWR 模式：先读缓存秒开 → 后台增量拉取
  Future<void> _loadCachedThenRefresh(int boardId, {String? type, String sort = 'time'}) async {
    final board = _ensureBoard(boardId);
    if (board.hasCacheLoaded) return;
    board.hasCacheLoaded = true;

    // 第一步：极速上屏 — 读本地缓存
    try {
      final cached = await PostCacheService.loadPosts(boardId);
      if (cached.isNotEmpty) {
        board.posts = cached;
        notifyListeners();
      }
    } catch (_) {}

    // 第二步 + 第三步：查找锚点，增量请求
    try {
      final since = await PostCacheService.getLatestTimestamp(boardId);
      board.sessionId = null; // 清除老的会话快照
      final params = <String, dynamic>{
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': 1,
        'limit': 20,
        'scene': 'refresh',
      };
      if (since != null) {
        params['since'] = since;
      }

      final response = await _dio.get('/posts', queryParameters: params);
      if (response.statusCode == 200) {
        final data = response.data;
        if (data['session_id'] != null) {
          board.sessionId = data['session_id'];
        }
        final newPosts = (data['posts'] as List)
            .map((e) => Post.fromJson(e))
            .toList();

        if (newPosts.isNotEmpty) {
          // 第四步：增量合并 — 更新已有帖子，插入新帖子
          bool changed = false;
          final existingIndexMap = {for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i};
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
            await PostCacheService.savePosts(boardId, board.posts);
          }
        }

        board.hasMore = newPosts.length >= 20;
        board.currentPage = 2;
      }
    } on DioException catch (e) {
      // 网络失败时，缓存已上屏，静默忽略
      debugPrint('增量拉取失败(board=$boardId): ${e.message}');
    } catch (e) {
      debugPrint('增量拉取异常(board=$boardId): $e');
    }

    board.hasLoaded = true;
    if (boardId == _activeBoardId) {
      _boards[_activeBoardId] = board;
    }
    notifyListeners();
  }

  /// 加载更多（翻页）
  Future<void> loadPosts(
      {int boardId = 1, String? type, String sort = 'time'}) async {
    final board = _ensureBoard(boardId);

    // 首次加载走 SWR
    if (!board.hasCacheLoaded) {
      await _loadCachedThenRefresh(boardId, type: type, sort: sort);
      return;
    }

    if (board.isLoading || !board.hasMore) return;
    board.isLoading = true;
    board.error = null;
    notifyListeners();

    try {
      final params = <String, dynamic>{
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': board.currentPage,
        'limit': 20,
      };

      final response = await _dio.get('/posts', queryParameters: params);
      if (response.statusCode == 200) {
        final data = response.data;
        if (data['session_id'] != null) {
          board.sessionId = data['session_id'];
        }
        final newPosts = (data['posts'] as List)
            .map((e) => Post.fromJson(e))
            .toList();

        if (board.currentPage == 1) {
          board.posts = newPosts;
        } else {
          final existingIndexMap = {for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i};
          for (final np in newPosts) {
            final idx = existingIndexMap[np.id];
            if (idx != null) {
              board.posts[idx] = np; // 更新已存在的帖子（比如有评论数更新）
            } else {
              board.posts.add(np); // 尾部追加新帖子
            }
          }
        }

        board.hasMore = newPosts.length >= 20 && newPosts.isNotEmpty;
        board.currentPage++;
      }
    } on DioException catch (e) {
      board.error = AppFeedback.dioErrorMessage(e);
    } catch (e) {
      board.error = e.toString();
    }

    board.isLoading = false;
    board.hasLoaded = true;
    if (boardId == _activeBoardId) {
      _boards[_activeBoardId] = board;
    }
    notifyListeners();
  }

  Future<void> refresh(
      {int boardId = 1, String? type, String sort = 'time'}) async {
    final board = _ensureBoard(boardId);
    bool isSortChanged = board.currentSort != sort;
    board.currentSort = sort;
    board.currentPage = 1;
    board.hasMore = true;

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
      if (response.statusCode == 200) {
        final newPosts = (response.data['posts'] as List)
            .map((e) => Post.fromJson(e))
            .toList();

        if (newPosts.isNotEmpty) {
          bool changed = false;
          final existingIndexMap = {for (var i = 0; i < board.posts.length; i++) board.posts[i].id: i};
          final uniqueNew = <Post>[];

          for (final np in newPosts) {
            final idx = existingIndexMap[np.id];
            if (idx != null) {
              board.posts[idx] = np;
              changed = true;
            } else {
              uniqueNew.add(np);
            }
          }

          if (uniqueNew.isNotEmpty) {
            board.posts = [...uniqueNew, ...board.posts];
            changed = true;
          }

          if (changed) {
            await PostCacheService.savePosts(boardId, board.posts);
          }
        }
        board.hasMore = newPosts.length >= 20;
      }
    } on DioException catch (e) {
      debugPrint('刷新失败(board=$boardId): ${e.message}');
    }

    if (boardId == _activeBoardId) {
      _boards[_activeBoardId] = board;
    }
    notifyListeners();
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
        return (data['posts'] as List).map((e) => Post.fromJson(e)).toList();
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
      final boardId = entry.key;
      final board = entry.value;
      final index = board.posts.indexWhere((p) => p.id == updated.id);
      if (index >= 0) {
        board.posts[index] = updated;
        // 同步持久化到本地缓存，防止杀后台后数据(如浏览量)倒退
        PostCacheService.savePosts(boardId, board.posts);
      }
    }
  }
}
