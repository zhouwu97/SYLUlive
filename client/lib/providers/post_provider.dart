import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'dart:io';
import '../models/post.dart';
import '../utils/app_feedback.dart';

/// 每个板块的帖子状态
class _BoardState {
  List<Post> posts = [];
  bool isLoading = false;
  String? error;
  int currentPage = 1;
  bool hasMore = true;
  bool hasLoaded = false;
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
  int _activeBoardId = 1;

  PostProvider(this._dio) {
    _boards[1] = _BoardState();
    _boards[2] = _BoardState();
  }

  // ---- 当前活跃板块 (兼容旧 getter，水帖 / 首页用) ----

  List<Post> get posts => _board.posts;
  bool get isLoading => _board.isLoading;
  String? get error => _board.error;
  bool get hasMore => _board.hasMore;
  bool get hasLoaded => _board.hasLoaded;

  _BoardState get _board => _boards[_activeBoardId]!;

  /// 获取指定板块的帖子列表
  List<Post> postsFor(int boardId) => _boards[boardId]?.posts ?? [];
  bool isLoadingFor(int boardId) => _boards[boardId]?.isLoading ?? false;
  bool hasLoadedFor(int boardId) => _boards[boardId]?.hasLoaded ?? false;

  Future<void> loadPosts(
      {int boardId = 1, String? type, String sort = 'time'}) async {
    final board = _boards[boardId]!;
    if (board.isLoading) return;

    board.isLoading = true;
    board.error = null;
    notifyListeners();

    try {
      final response = await _dio.get('/posts', queryParameters: {
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': board.currentPage,
        'limit': 20,
      });

      if (response.statusCode == 200) {
        final data = response.data;
        final List<Post> newPosts =
            (data['posts'] as List).map((e) => Post.fromJson(e)).toList();

        if (board.currentPage == 1) {
          board.posts = newPosts;
        } else {
          board.posts.addAll(newPosts);
        }

        board.hasMore = newPosts.length >= 20 && newPosts.isNotEmpty;
        board.currentPage++;
      }
    } on DioException catch (e) {
      board.error = AppFeedback.dioErrorMessage(e);
      debugPrint('加载帖子失败: ${board.error}');
    } catch (e) {
      board.error = e.toString();
      debugPrint('加载帖子失败: ${board.error}');
    }

    board.isLoading = false;
    board.hasLoaded = true;

    // 同时更新活跃板块引用
    if (boardId == _activeBoardId) {
      _boards[_activeBoardId] = board;
    }

    notifyListeners();
  }

  Future<void> refresh(
      {int boardId = 1, String? type, String sort = 'time'}) async {
    final board = _boards[boardId]!;
    board.currentPage = 1;
    board.hasMore = true;
    await loadPosts(boardId: boardId, type: type, sort: sort);
  }

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
      debugPrint('创建帖子失败: $msg');
      return CreatePostResult(success: false, errorMessage: msg);
    } catch (e) {
      debugPrint('创建帖子失败: $e');
      return CreatePostResult(success: false, errorMessage: '创建帖子失败: $e');
    }
  }

  /// 上传单张图片，返回 file_id，失败返回 null
  Future<int?> uploadImage(String filePath) async {
    try {
      // 处理 Android content:// URI
      String uploadPath = filePath;
      if (filePath.startsWith('content://')) {
        // 复制到临时文件
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
      debugPrint('上传响应: status=${response.statusCode}, data=${response.data}');
      if (response.statusCode == 200 && response.data != null) {
        final fileId = response.data['file_id'];
        debugPrint('上传成功: file_id=$fileId');
        return fileId as int?;
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
      debugPrint('删除帖子失败: $msg');
      return DeletePostResult(success: false, errorMessage: msg);
    } catch (e) {
      final msg = '删除帖子失败: $e';
      debugPrint(msg);
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
      debugPrint('删除评论失败: $msg');
      return DeletePostResult(success: false, errorMessage: msg);
    } catch (e) {
      final msg = '删除评论失败: $e';
      debugPrint(msg);
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
}
