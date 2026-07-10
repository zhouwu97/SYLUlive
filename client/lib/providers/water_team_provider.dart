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

  // 按 ID 隔离的加载与错误状态
  bool _loadingMyApplications = false;
  final Set<int> _loadingRecruitmentIds = {};
  final Set<int> _processingApplicationIds = {};
  final Set<int> _processingRecruitmentIds = {};
  final Map<int, String?> _errorsByRecruitment = {};

  final Map<int, List<WaterTeamApplication>> _applicationsByRecruitment = {};
  List<WaterTeamApplication>? _myApplications;

  WaterTeamProvider(this._dio, this._postProvider)
      : _service = WaterTeamService(_dio);

  bool get isLoadingMyApplications => _loadingMyApplications;
  bool isRecruitmentLoading(int recruitmentId) =>
      _loadingRecruitmentIds.contains(recruitmentId);
  bool isApplicationProcessing(int applicationId) =>
      _processingApplicationIds.contains(applicationId);
  bool isRecruitmentProcessing(int recruitmentId) =>
      _processingRecruitmentIds.contains(recruitmentId);
  String? errorFor(int recruitmentId) => _errorsByRecruitment[recruitmentId];

  List<WaterTeamApplication> applicationsFor(int recruitmentId) =>
      List.unmodifiable(_applicationsByRecruitment[recruitmentId] ?? const []);
  List<WaterTeamApplication> get myApplications =>
      List.unmodifiable(_myApplications ?? const []);

  // ---- 申请加入 ----
  Future<WaterTeamApplication?> apply({
    required int recruitmentId,
    required String message,
    String availability = '',
    int? postId,
  }) async {
    _processingRecruitmentIds.add(recruitmentId);
    notifyListeners();
    try {
      final application = await _service.apply(
        recruitmentId: recruitmentId,
        message: message,
        availability: availability,
      );
      if (postId != null) await _refreshPostAndFeeds(postId);
      return application;
    } on DioException catch (error) {
      _errorsByRecruitment[recruitmentId] =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      notifyListeners();
      return null;
    } catch (error) {
      _errorsByRecruitment[recruitmentId] = error.toString();
      notifyListeners();
      return null;
    } finally {
      _processingRecruitmentIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  // ---- 取消申请 ----
  Future<bool> cancel({required int applicationId, int? postId}) async {
    _processingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      await _service.cancel(applicationId: applicationId);
      if (postId != null) await _refreshPostAndFeeds(postId);
      return true;
    } on DioException catch (error) {
      _errorsByRecruitment[0] =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      notifyListeners();
      return false;
    } catch (error) {
      _errorsByRecruitment[0] = error.toString();
      notifyListeners();
      return false;
    } finally {
      _processingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  // ---- 我的申请 ----
  Future<List<WaterTeamApplication>> loadMyApplications({
    bool force = false,
  }) async {
    if (!force && _myApplications != null) return myApplications;
    _loadingMyApplications = true;
    notifyListeners();
    try {
      final value = await _service.getMyApplications();
      _myApplications = value;
      return value;
    } on DioException catch (error) {
      debugPrint('加载我的申请失败: ${error.message}');
      return const [];
    } catch (error) {
      debugPrint('加载我的申请失败: $error');
      return const [];
    } finally {
      _loadingMyApplications = false;
      notifyListeners();
    }
  }

  // ---- 招募申请列表 ----
  Future<List<WaterTeamApplication>> loadRecruitmentApplications(
    int recruitmentId, {
    bool force = false,
  }) async {
    if (!force && _applicationsByRecruitment.containsKey(recruitmentId)) {
      return applicationsFor(recruitmentId);
    }
    _loadingRecruitmentIds.add(recruitmentId);
    _errorsByRecruitment.remove(recruitmentId);
    notifyListeners();
    try {
      final value = await _service.getRecruitmentApplications(
        recruitmentId: recruitmentId,
      );
      _applicationsByRecruitment[recruitmentId] = value;
      return value;
    } on DioException catch (error) {
      _errorsByRecruitment[recruitmentId] =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      return const [];
    } catch (error) {
      _errorsByRecruitment[recruitmentId] = error.toString();
      return const [];
    } finally {
      _loadingRecruitmentIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  // ---- 审批（通过 / 拒绝） ----
  Future<bool> review({
    required int applicationId,
    required bool accept,
    String reply = '',
    int? recruitmentId,
    int? postId,
  }) async {
    _processingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      if (accept) {
        await _service.accept(applicationId: applicationId, reply: reply);
      } else {
        await _service.reject(applicationId: applicationId, reply: reply);
      }
      // 审批完成后重新拉取申请列表
      if (recruitmentId != null) {
        await loadRecruitmentApplications(recruitmentId, force: true);
      }
      if (postId != null) await _refreshPostAndFeeds(postId);
      return true;
    } on DioException catch (error) {
      _errorsByRecruitment[recruitmentId ?? 0] =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      notifyListeners();
      return false;
    } catch (error) {
      _errorsByRecruitment[recruitmentId ?? 0] = error.toString();
      notifyListeners();
      return false;
    } finally {
      _processingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  // ---- 招募状态（关闭 / 重新开启） ----
  Future<bool> updateRecruitmentStatus({
    required int recruitmentId,
    required String status,
    int? postId,
  }) async {
    _processingRecruitmentIds.add(recruitmentId);
    notifyListeners();
    try {
      final updated = await _service.updateRecruitmentStatus(
        recruitmentId: recruitmentId,
        status: status,
      );
      _postProvider.updatePostInCache(updated);
      // 状态变化通常会影响列表排序
      if (updated.waterTagId != null && updated.postType.isNotEmpty) {
        await _postProvider.refreshTeamTagFeeds(
          tagId: updated.waterTagId!,
          postType: updated.postType,
        );
      }
      return true;
    } on DioException catch (error) {
      _errorsByRecruitment[recruitmentId] =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      notifyListeners();
      return false;
    } catch (error) {
      _errorsByRecruitment[recruitmentId] = error.toString();
      notifyListeners();
      return false;
    } finally {
      _processingRecruitmentIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  /// 刷新单个帖子并触发组队信息流重排。
  Future<void> _refreshPostAndFeeds(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId');
      final post = Post.fromJson(response.data as Map<String, dynamic>);
      _postProvider.updatePostInCache(post);
      // 影响排序的状态变化（如申请后名单变化）需要重拉信息流
      if (post.waterTagId != null && post.postType.isNotEmpty) {
        await _postProvider.refreshTeamTagFeeds(
          tagId: post.waterTagId!,
          postType: post.postType,
        );
      }
    } on DioException catch (error) {
      debugPrint('刷新组队帖子失败: ${error.message}');
    }
  }

  /// 刷新单个帖子详情（不触发信息流重排，供详情页内部使用）。
  Future<Post?> refreshPostDetailOnly(int postId) async {
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
}
