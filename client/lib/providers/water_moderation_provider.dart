import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/water_moderation.dart';
import '../services/water_moderation_service.dart';

/// 水帖版块内容管理 Provider
class WaterModerationProvider extends ChangeNotifier {
  final WaterModerationService _service;

  final Map<String, List<WaterSectionMute>> _mutesBySlug = {};
  final Map<String, WaterModerationLogPage> _logsBySlug = {};

  bool _isOperating = false;
  bool _isLoadingMutes = false;
  bool _isLoadingLogs = false;
  String? _error;

  WaterModerationProvider(Dio dio) : _service = WaterModerationService(dio);

  bool get isOperating => _isOperating;
  bool get isLoadingMutes => _isLoadingMutes;
  bool get isLoadingLogs => _isLoadingLogs;
  String? get error => _error;

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
    return _operation(
        () async => await _service.unpinPost(sectionSlug: sectionSlug, postId: postId));
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
      final statusCode = e.response?.statusCode;
      if (statusCode == 400) {
        _error = _extractError(e.response?.data) ?? '请求参数有误';
      } else if (statusCode == 403) {
        _error = '没有该操作权限';
      } else {
        _error = '操作失败，请稍后重试';
      }
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
    if (data is Map && data['error'] is String) {
      return data['error'];
    }
    return null;
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
