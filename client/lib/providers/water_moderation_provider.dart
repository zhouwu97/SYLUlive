import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/water_moderation.dart';
import '../services/water_moderation_service.dart';

/// 版块加精操作结果：ok 表示版块精华已生效；homePending 表示首页推荐审核已提交。
class FeaturePostOutcome {
  const FeaturePostOutcome({
    required this.ok,
    this.homePending = false,
    this.error,
  });

  final bool ok;
  final bool homePending;
  final String? error;
}

/// 水帖版块内容管理 Provider
class WaterModerationProvider extends ChangeNotifier {
  final WaterModerationService _service;

  final Map<String, List<WaterSectionMute>> _mutesBySlug = {};
  final Map<String, WaterModerationLogPage> _logsBySlug = {};

  bool _isOperating = false;
  bool _isLoadingMutes = false;
  bool _isLoadingLogs = false;
  String? _error;
  int? _sessionUserId;

  WaterModerationProvider(Dio dio) : _service = WaterModerationService(dio);

  bool get isOperating => _isOperating;
  bool get isLoadingMutes => _isLoadingMutes;
  bool get isLoadingLogs => _isLoadingLogs;
  String? get error => _error;

  void syncSessionUser(int? userId) {
    if (_sessionUserId == userId) return;
    _sessionUserId = userId;
    _mutesBySlug.clear();
    _logsBySlug.clear();
    _error = null;
  }

  List<WaterSectionMute> mutesOf(String slug) => _mutesBySlug[slug] ?? [];
  WaterModerationLogPage logsOf(String slug) =>
      _logsBySlug[slug] ?? const WaterModerationLogPage();

  // ── 操作 ──

  Future<bool> pinPost({
    required String sectionSlug,
    required int postId,
    int weight = 0,
    String? reason,
    DateTime? pinnedUntil,
  }) async {
    return _operation(() async {
      await _service.pinPost(
        sectionSlug: sectionSlug,
        postId: postId,
        weight: weight,
        reason: reason,
        pinnedUntil: pinnedUntil,
      );
    });
  }

  Future<bool> unpinPost({
    required String sectionSlug,
    required int postId,
  }) async {
    return _operation(() async =>
        await _service.unpinPost(sectionSlug: sectionSlug, postId: postId));
  }

  /// 返回 [FeaturePostOutcome]：homePending 由服务端回传的 home_application 决定，
  /// 不再乐观假定“首页推荐待审核”一定成立。
  Future<FeaturePostOutcome> featurePost({
    required String sectionSlug,
    required int postId,
    required String reason,
  }) async {
    _isOperating = true;
    _error = null;
    notifyListeners();
    try {
      final data = await _service.featurePost(
        sectionSlug: sectionSlug,
        postId: postId,
        reason: reason,
      );
      _isOperating = false;
      final home = data?['home_application'];
      final homePending = home is Map && home['status'] == 'pending';
      notifyListeners();
      return FeaturePostOutcome(ok: true, homePending: homePending);
    } on DioException catch (e) {
      _isOperating = false;
      _error = _mapOperationError(e);
      notifyListeners();
      return FeaturePostOutcome(ok: false, error: _error);
    } catch (e) {
      _isOperating = false;
      _error = '操作失败，请稍后重试';
      notifyListeners();
      return FeaturePostOutcome(ok: false, error: _error);
    }
  }

  Future<bool> unfeaturePost({
    required String sectionSlug,
    required int postId,
  }) async {
    return _operation(() async =>
        await _service.unfeaturePost(sectionSlug: sectionSlug, postId: postId));
  }

  Future<bool> deletePostByModerator({
    required String sectionSlug,
    required int postId,
    required String reason,
  }) async {
    return _operation(() async {
      await _service.deletePostByModerator(
        sectionSlug: sectionSlug,
        postId: postId,
        reason: reason,
      );
    });
  }

  Future<bool> restorePost({
    required String sectionSlug,
    required int postId,
    String? reason,
  }) async {
    return _operation(() async {
      await _service.restorePost(
        sectionSlug: sectionSlug,
        postId: postId,
        reason: reason,
      );
    });
  }

  Future<bool> muteUser({
    required String sectionSlug,
    required int userId,
    required String reason,
    required DateTime until,
  }) async {
    return _operation(() async {
      await _service.muteUser(
        sectionSlug: sectionSlug,
        userId: userId,
        reason: reason,
        until: until,
      );
    });
  }

  Future<bool> unmuteUser({
    required String sectionSlug,
    required int userId,
    String? reason,
  }) async {
    return _operation(() async {
      await _service.unmuteUser(
        sectionSlug: sectionSlug,
        userId: userId,
        reason: reason,
      );
    });
  }

  Future<bool> _operation(Future<void> Function() fn) async {
    _isOperating = true;
    _error = null;
    notifyListeners();
    try {
      await fn();
      _isOperating = false;
      notifyListeners();
      return true;
    } on DioException catch (e) {
      _isOperating = false;
      _error = _mapOperationError(e);
      notifyListeners();
      return false;
    } catch (e) {
      _isOperating = false;
      _error = '操作失败，请稍后重试';
      notifyListeners();
      return false;
    }
  }

  String? _extractError(dynamic data) {
    if (data is Map) {
      final detail = data['error'] ?? data['message'];
      if (detail is String && detail.trim().isNotEmpty) {
        return detail.trim();
      }
    }
    return null;
  }

  String _mapOperationError(DioException e) {
    switch (e.response?.statusCode) {
      case 400:
        final message = _extractError(e.response?.data);
        if (message == null) return '操作参数不正确';
        if (message.contains('置顶已达上限')) {
          return '该版块最多置顶 3 条帖子';
        }
        if (message.contains('禁言时长不能超过')) {
          return '禁言时间超出允许范围';
        }
        return message;
      case 403:
        return '没有该操作权限';
      case 409:
        return '当前状态已变化，请刷新后重试';
      case 500:
        // 透传服务端真实错误（如“已设为版块精华，首页推荐提交失败”）
        final message = _extractError(e.response?.data);
        return message ?? '操作失败，请稍后重试';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return '网络异常，请稍后重试';
      default:
        return '操作失败，请稍后重试';
    }
  }

  // ── 禁言列表 ──

  Future<void> loadMutes(String slug) async {
    _isLoadingMutes = true;
    notifyListeners();
    try {
      final list = await _service.fetchMutes(slug);
      _mutesBySlug[slug] = list;
    } catch (e) {
      _mutesBySlug[slug] = [];
      debugPrint('loadMutes($slug) failed: $e');
    } finally {
      _isLoadingMutes = false;
      notifyListeners();
    }
  }

  // ── 操作日志 ──

  Future<void> loadLogs(String slug, {int page = 1, String? action}) async {
    _isLoadingLogs = true;
    notifyListeners();
    try {
      final pageData = await _service.fetchLogs(
          sectionSlug: slug, page: page, action: action);
      _logsBySlug[slug] = pageData;
    } catch (e) {
      if (!_logsBySlug.containsKey(slug)) {
        _logsBySlug[slug] = const WaterModerationLogPage();
      }
      debugPrint('loadLogs($slug) failed: $e');
    } finally {
      _isLoadingLogs = false;
      notifyListeners();
    }
  }
}
