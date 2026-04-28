import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/post.dart';

class PostProvider extends ChangeNotifier {
  final Dio _dio;

  List<Post> _posts = [];
  bool _isLoading = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;

  List<Post> get posts => _posts;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasMore => _hasMore;

  PostProvider(this._dio);

  Future<void> loadPosts({int boardId = 1, String? type, String sort = 'time'}) async {
    if (_isLoading) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _dio.get('/posts', queryParameters: {
        'board': boardId,
        'type': type,
        'sort': sort,
        'page': _currentPage,
        'limit': 20,
      });

      if (response.statusCode == 200) {
        final data = response.data;
        final List<Post> newPosts = (data['posts'] as List)
            .map((e) => Post.fromJson(e))
            .toList();

        if (_currentPage == 1) {
          _posts = newPosts;
        } else {
          _posts.addAll(newPosts);
        }

        _hasMore = newPosts.length >= 20 && newPosts.isNotEmpty;
        _currentPage++;
      }
    } on DioException catch (e) {
      _error = e.message ?? '网络错误';
      debugPrint('加载帖子失败: $_error');
    } catch (e) {
      _error = e.toString();
      debugPrint('加载帖子失败: $_error');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> refresh({int boardId = 1, String? type, String sort = 'time'}) async {
    _currentPage = 1;
    _hasMore = true;
    await loadPosts(boardId: boardId, type: type, sort: sort);
  }

  Future<bool> createPost({
    required int boardId,
    required String content,
    String? title,
    String? postType,
    double? price,
    String? contact,
    List<String>? imagePaths,
  }) async {
    try {
      final formData = FormData.fromMap({
        'board_id': boardId,
        'content': content,
        if (title != null) 'title': title,
        if (postType != null) 'post_type': postType,
        if (price != null) 'price': price,
        if (contact != null) 'contact': contact,
      });

      final response = await _dio.post('/posts', data: formData);
      return response.statusCode == 201;
    } catch (e) {
      debugPrint('创建帖子失败: $e');
      return false;
    }
  }

  Future<bool> deletePost(int postId) async {
    try {
      final response = await _dio.delete('/posts/$postId');
      if (response.statusCode == 200) {
        _posts.removeWhere((p) => p.id == postId);
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('删除帖子失败: $e');
    }
    return false;
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