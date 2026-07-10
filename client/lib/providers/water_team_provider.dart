import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/post.dart';
import '../models/water_team.dart';
import '../services/water_team_service.dart';
import 'post_provider.dart';

/// 组队申请状态，按招募 ID 隔离，避免不同帖子之间互相覆盖。
class WaterTeamProvider extends ChangeNotifier {
  final Dio _dio;
  final WaterTeamService _service;
  final PostProvider _postProvider;

  bool _isLoading = false;
  String? _error;
  final Map<int, List<WaterTeamApplication>> _applicationsByRecruitment = {};
  List<WaterTeamApplication>? _myApplications;

  WaterTeamProvider(this._dio, this._postProvider)
      : _service = WaterTeamService(_dio);

  bool get isLoading => _isLoading;
  String? get error => _error;
  List<WaterTeamApplication> applicationsFor(int recruitmentId) =>
      List.unmodifiable(_applicationsByRecruitment[recruitmentId] ?? const []);
  List<WaterTeamApplication> get myApplications =>
      List.unmodifiable(_myApplications ?? const []);

  Future<WaterTeamApplication?> apply({
    required int recruitmentId,
    required String message,
    String availability = '',
    int? postId,
  }) async {
    return _run(() async {
      final application = await _service.apply(
        recruitmentId: recruitmentId,
        message: message,
        availability: availability,
      );
      if (postId != null) await refreshPost(postId);
      return application;
    });
  }

  Future<bool> cancel({required int applicationId, int? postId}) async {
    return (await _run(() async {
          await _service.cancel(applicationId: applicationId);
          if (postId != null) await refreshPost(postId);
          return true;
        })) ??
        false;
  }

  Future<List<WaterTeamApplication>> loadMyApplications({
    bool force = false,
  }) async {
    if (!force && _myApplications != null) return myApplications;
    return (await _run(() async {
          final value = await _service.getMyApplications();
          _myApplications = value;
          return value;
        })) ??
        const [];
  }

  Future<List<WaterTeamApplication>> loadRecruitmentApplications(
    int recruitmentId, {
    bool force = false,
  }) async {
    if (!force && _applicationsByRecruitment.containsKey(recruitmentId)) {
      return applicationsFor(recruitmentId);
    }
    return (await _run(() async {
          final value = await _service.getRecruitmentApplications(
            recruitmentId: recruitmentId,
          );
          _applicationsByRecruitment[recruitmentId] = value;
          return value;
        })) ??
        const [];
  }

  Future<bool> review({
    required int applicationId,
    required bool accept,
    String reply = '',
    int? recruitmentId,
    int? postId,
  }) async {
    return (await _run(() async {
          if (accept) {
            await _service.accept(applicationId: applicationId, reply: reply);
          } else {
            await _service.reject(applicationId: applicationId, reply: reply);
          }
          if (recruitmentId != null) {
            await loadRecruitmentApplications(recruitmentId, force: true);
          }
          if (postId != null) await refreshPost(postId);
          return true;
        })) ??
        false;
  }

  Future<bool> updateRecruitmentStatus({
    required int recruitmentId,
    required String status,
    int? postId,
  }) async {
    return (await _run(() async {
          final updated = await _service.updateRecruitmentStatus(
            recruitmentId: recruitmentId,
            status: status,
          );
          _postProvider.updatePostInCache(updated);
          if (postId != null && updated.id != postId) await refreshPost(postId);
          return true;
        })) ??
        false;
  }

  Future<Post?> refreshPost(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId');
      final post = Post.fromJson(response.data as Map<String, dynamic>);
      _postProvider.updatePostInCache(post);
      return post;
    } on DioException catch (error) {
      debugPrint('刷新组队帖子失败: ${error.message}');
      return null;
    }
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      return await action();
    } on DioException catch (error) {
      _error = error.response?.data is Map
          ? (error.response!.data['error'] ?? error.message).toString()
          : error.message ?? '网络请求失败';
      return null;
    } catch (error) {
      _error = error.toString();
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
