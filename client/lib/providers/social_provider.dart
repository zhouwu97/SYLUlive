import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/user.dart';
import '../models/post.dart';

class SocialProvider extends ChangeNotifier {
  final Dio _dio;
  bool _isLoading = false;

  SocialProvider(this._dio);

  bool get isLoading => _isLoading;

  Future<bool> follow(int userId) async {
    try {
      final response = await _dio.post('/user/$userId/follow');
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      debugPrint('关注失败: $e');
      return false;
    }
  }

  Future<bool> unfollow(int userId) async {
    try {
      final response = await _dio.delete('/user/$userId/follow');
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('取消关注失败: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> getFollowers(
    int userId, {
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/user/$userId/followers',
        queryParameters: {'page': page, 'limit': limit},
      );
      return response.data;
    } catch (e) {
      debugPrint('获取粉丝失败: $e');
      return {'items': [], 'total': 0, 'page': page, 'limit': limit};
    }
  }

  Future<Map<String, dynamic>> getFollowing(
    int userId, {
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/user/$userId/following',
        queryParameters: {'page': page, 'limit': limit},
      );
      return response.data;
    } catch (e) {
      debugPrint('获取关注列表失败: $e');
      return {'items': [], 'total': 0, 'page': page, 'limit': limit};
    }
  }

  Future<User?> getUserProfile(int userId) async {
    try {
      _isLoading = true;
      notifyListeners();
      final response = await _dio.get('/user/$userId');
      _isLoading = false;
      notifyListeners();
      return User.fromJson(response.data);
    } catch (e) {
      debugPrint('获取用户信息失败: $e');
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  Future<List<Post>> getUserPosts(
    int userId, {
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/user/$userId/posts',
        queryParameters: {'page': page, 'limit': limit},
      );
      final List<dynamic> data = response.data;
      return data.map((json) => Post.fromJson(json)).toList();
    } catch (e) {
      debugPrint('获取用户帖子失败: $e');
      return [];
    }
  }
}
