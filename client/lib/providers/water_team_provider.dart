import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/post.dart';
import '../models/water_team.dart';
import '../services/water_team_service.dart';
import 'post_provider.dart';

/// 组队变更操作的结果。
///
/// - [success]=false：业务接口失败，[error] 非空。
/// - [success]=true, [post]!=null：业务成功且帖子已刷新。
/// - [success]=true, [post]=null：业务成功但帖子同步刷新失败，UI 应做延迟更新。
class TeamMutationResult {
  final bool success;
  final Post? post;
  final String? error;

  const TeamMutationResult({
    required this.success,
    this.post,
    this.error,
  });

  /// 业务成功（无论帖子是否刷新成功）。
  bool get isSuccess => success;

  /// 业务成功且帖子可用。
  bool get hasPost => success && post != null;
}

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
  Future<TeamMutationResult> apply({
    required int recruitmentId,
    required int postId,
    required String message,
    String availability = '',
  }) async {
    _processingRecruitmentIds.add(recruitmentId);
    notifyListeners();
    try {
      await _service.apply(
        recruitmentId: recruitmentId,
        message: message,
        availability: availability,
      );
      // 业务已成功，接下来同步帖子。帖子刷新失败不覆盖业务成功。
      final post = await _refreshPostAndFeeds(postId);
      return TeamMutationResult(success: true, post: post);
    } on DioException catch (error) {
      return TeamMutationResult(
        success: false,
        error: _extractError(error),
      );
    } catch (error) {
      return TeamMutationResult(success: false, error: error.toString());
    } finally {
      _processingRecruitmentIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  // ---- 取消申请 ----
  Future<TeamMutationResult> cancel({
    required int applicationId,
    required int recruitmentId,
    required int postId,
  }) async {
    _processingApplicationIds.add(applicationId);
    notifyListeners();
    try {
      await _service.cancel(applicationId: applicationId);
      final post = await _refreshPostAndFeeds(postId);
      return TeamMutationResult(success: true, post: post);
    } on DioException catch (error) {
      return TeamMutationResult(
        success: false,
        error: _extractError(error),
      );
    } catch (error) {
      return TeamMutationResult(success: false, error: error.toString());
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
      _myApplicationsError = _extractError(error);
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
      _errorsByRecruitment[recruitmentId] = _extractError(error);
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
  Future<TeamMutationResult> review({
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
      Post? post;
      if (postId != null) {
        post = await _refreshPostAndFeeds(postId);
      }
      return TeamMutationResult(success: true, post: post);
    } on DioException catch (error) {
      return TeamMutationResult(
        success: false,
        error: _extractError(error),
      );
    } catch (error) {
      return TeamMutationResult(success: false, error: error.toString());
    } finally {
      _processingApplicationIds.remove(applicationId);
      notifyListeners();
    }
  }

  // ---- 招募状态（关闭 / 重新开启） ----
  Future<TeamMutationResult> updateRecruitmentStatus({
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
      return TeamMutationResult(success: true, post: updated);
    } on DioException catch (error) {
      return TeamMutationResult(
        success: false,
        error: _extractError(error),
      );
    } catch (error) {
      return TeamMutationResult(success: false, error: error.toString());
    } finally {
      _processingRecruitmentIds.remove(recruitmentId);
      notifyListeners();
    }
  }

  /// 刷新帖子详情并重排组队信息流，返回最新 [Post]（失败返回 null）。
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

  static String? _extractError(DioException error) {
    // 服务端统一错误格式为 {code, message, request_id}，error 仅旧接口兜底。
    return error.response?.data is Map
        ? (error.response!.data['message'] ??
                error.response!.data['error'] ??
                error.message)
            .toString()
        : error.message ?? '网络请求失败';
  }
}
