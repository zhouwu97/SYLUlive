import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/water_moderator.dart';
import '../services/water_moderator_service.dart';

/// 水帖版主管理 Provider。
/// 管理当前用户权限缓存和版主列表的加载/增删改。
class WaterModeratorProvider extends ChangeNotifier {
  static const _permissionCacheTtl = Duration(minutes: 1);

  final WaterModeratorService _service;

  final Map<String, WaterSectionPermission> _permissionBySlug = {};
  final Map<String, DateTime> _permissionLoadedAt = {};
  final Map<String, List<WaterSectionModerator>> _moderatorsBySlug = {};
  int? _sessionUserId;

  bool _isLoadingPermission = false;
  bool _isLoadingModerators = false;
  String? _error;

  WaterModeratorProvider(Dio dio) : _service = WaterModeratorService(dio);

  bool get isLoadingPermission => _isLoadingPermission;
  bool get isLoadingModerators => _isLoadingModerators;
  String? get error => _error;

  void syncSessionUser(int? userId) {
    if (_sessionUserId == userId) return;
    _sessionUserId = userId;
    _permissionBySlug.clear();
    _permissionLoadedAt.clear();
    _moderatorsBySlug.clear();
    _error = null;
  }

  // ── 权限 ──

  /// 获取已缓存的权限；没有返回 empty。
  WaterSectionPermission permissionOf(String slug) =>
      _permissionBySlug[slug] ?? WaterSectionPermission.empty();

  /// 加载当前用户在某个 section 的权限。带 1 分钟轻缓存。
  Future<void> loadMyPermission(String slug,
      {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final loadedAt = _permissionLoadedAt[slug];
      if (loadedAt != null &&
          DateTime.now().difference(loadedAt) < _permissionCacheTtl &&
          _permissionBySlug.containsKey(slug)) {
        return;
      }
    }
    if (_isLoadingPermission) return;
    _isLoadingPermission = true;
    notifyListeners();

    try {
      final perm = await _service.fetchMyPermission(slug);
      _permissionBySlug[slug] = perm;
      _permissionLoadedAt[slug] = DateTime.now();
      _error = null;
    } catch (e) {
      // 403 / 404 / 500 都不崩溃，返回 empty 并在 UI 隐藏入口
      _permissionBySlug[slug] = WaterSectionPermission.empty();
      _permissionLoadedAt[slug] = DateTime.now();
      debugPrint('loadMyPermission($slug) failed: $e');
    } finally {
      _isLoadingPermission = false;
      notifyListeners();
    }
  }

  // ── 版主列表 ──

  List<WaterSectionModerator> moderatorsOf(String slug) =>
      _moderatorsBySlug[slug] ?? [];

  Future<void> loadModerators(String slug) async {
    if (_isLoadingModerators) return;
    _isLoadingModerators = true;
    _error = null;
    notifyListeners();

    try {
      final list = await _service.fetchModerators(slug);
      _moderatorsBySlug[slug] = list;
    } catch (e) {
      _moderatorsBySlug[slug] = [];
      debugPrint('loadModerators($slug) failed: $e');
      rethrow;
    } finally {
      _isLoadingModerators = false;
      notifyListeners();
    }
  }

  // ── 增 / 改 / 删 ──

  Future<WaterSectionModerator?> createModerator({
    required String sectionSlug,
    required int userId,
    required String role,
    required bool canEditSection,
    required bool canManageTags,
    required bool canPinPost,
    required bool canDeletePost,
    required bool canMuteUser,
    String? reason,
  }) async {
    try {
      final mod = await _service.createModerator(
        sectionSlug: sectionSlug,
        userId: userId,
        role: role,
        canEditSection: canEditSection,
        canManageTags: canManageTags,
        canPinPost: canPinPost,
        canDeletePost: canDeletePost,
        canMuteUser: canMuteUser,
        reason: reason,
      );
      await _refreshModeratorList(sectionSlug);
      return mod;
    } catch (e) {
      debugPrint('createModerator failed: $e');
      rethrow;
    }
  }

  Future<WaterSectionModerator?> updateModerator({
    required String sectionSlug,
    required int moderatorId,
    String? role,
    bool? canEditSection,
    bool? canManageTags,
    bool? canPinPost,
    bool? canDeletePost,
    bool? canMuteUser,
    String? reason,
  }) async {
    try {
      final mod = await _service.updateModerator(
        sectionSlug: sectionSlug,
        moderatorId: moderatorId,
        role: role,
        canEditSection: canEditSection,
        canManageTags: canManageTags,
        canPinPost: canPinPost,
        canDeletePost: canDeletePost,
        canMuteUser: canMuteUser,
        reason: reason,
      );
      await _refreshModeratorList(sectionSlug);
      return mod;
    } catch (e) {
      debugPrint('updateModerator failed: $e');
      rethrow;
    }
  }

  Future<void> revokeModerator({
    required String sectionSlug,
    required int moderatorId,
    String? reason,
  }) async {
    try {
      await _service.revokeModerator(
        sectionSlug: sectionSlug,
        moderatorId: moderatorId,
        reason: reason,
      );
      await _refreshModeratorList(sectionSlug);
    } catch (e) {
      debugPrint('revokeModerator failed: $e');
      rethrow;
    }
  }

  Future<void> _refreshModeratorList(String slug) async {
    try {
      await loadModerators(slug);
    } catch (_) {}
  }
}
