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
  /// 返回 [WaterTeamApplication] 表示成功；`null` 表示失败（错误见 [errorFor]）。
  Future<WaterTeamApplication?> apply({
    required int recruitmentId,
    required String message,
    String availability = '',
  }) async {
    _processingRecruitmentIds.add(recruitmentId);
    notifyListeners();
    try {
      final application = await _service.apply(
        recruitmentId: recruitmentId,
        message: message,
        availability: availability,
      );
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
  Future<bool> cancel({
    required int applicationId,
    required int recruitmentId,
  }) async {
    _processingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      await _service.cancel(applicationId: applicationId);
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
      _processingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  // ---- 我的申请 ----
  String? _myApplicationsError;

  String? get myApplicationsError => _myApplicationsError;

  Future<List<WaterTeamApplication>> loadMyApplications({
    bool force = false,
  }) async {
    if (!force && _myApplications != null) return myApplications;
    _loadingMyApplications = true;
    _myApplicationsError = null;
    notifyListeners();
    try {
      final value = await _service.getMyApplications();
      _myApplications = value;
      return value;
    } on DioException catch (error) {
      _myApplicationsError =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      return const [];
    } catch (error) {
      _myApplicationsError = error.toString();
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
  /// 返回最新的 [Post]；失败时返回 `null`。
  Future<Post?> review({
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
      if (recruitmentId != null) {
        await loadRecruitmentApplications(recruitmentId, force: true);
      }
      if (postId != null) return await _refreshPostAndFeeds(postId);
      return null;
    } on DioException catch (error) {
      final id = recruitmentId ?? 0;
      _errorsByRecruitment[id] =
          error.response?.data is Map
              ? (error.response!.data['error'] ?? error.message).toString()
              : error.message ?? '网络请求失败';
      notifyListeners();
      return null;
    } catch (error) {
      final id = recruitmentId ?? 0;
      _errorsByRecruitment[id] = error.toString();
      notifyListeners();
      return null;
    } finally {
      _processingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  // ---- 招募状态（关闭 / 重新开启） ----
  /// 返回更新后的 [Post]；失败时返回 `null`。
  Future<Post?> updateRecruitmentStatus({
    required int recruitmentId,
    required String status,
  }) async {
    _processingRecruitmentIds.add(recruitmentId);
    notifyListeners();
    try {
      final updated = await _service.updateRecruitmentStatus(
        recruitmentId: recruitmentId,
        status: status,
      );
      _postProvider.updatePostInCache(updated);
      if (updated.waterTagId != null && updated.postType.isNotEmpty) {
        await _postProvider.refreshTeamTagFeeds(
          tagId: updated.waterTagId!,
          postType: updated.postType,
        );
      }
      return updated;
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

  /// 刷新帖子详情并重排组队信息流，返回最新 [Post]。
  Future<Post?> _refreshPostAndFeeds(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId');
      final post = Post.fromJson(response.data as Map<String, dynamic>);
      _postProvider.updatePostInCache(post);
      if (post.waterTagId != null && post.postType.isNotEmpty) {
        await _postProvider.refreshTeamTagFeeds(
          tagId: post.waterTagId!,
          postType: post.postType,
        );
      }
      return post;
    } on DioException catch (error) {
      debugPrint('刷新组队帖子失败: ${error.message}');
      return null;
    }
  }
}
