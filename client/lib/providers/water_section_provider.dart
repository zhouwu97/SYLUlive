import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../config/water_post_taxonomy.dart';
import '../models/water_section.dart';
import '../services/water_section_service.dart';
import '../services/water_section_icon_review_service.dart';

/// 管理水帖版块的缓存与 fallback。
/// 接口失败时使用 kWaterPostCategories 转出的 fallback 版块，保证离线可用。
class WaterSectionProvider extends ChangeNotifier {
  static const _cacheTtl = Duration(minutes: 5);

  final WaterSectionService? _service;
  final WaterSectionIconReviewService? _iconReviewService;

  List<WaterSection> _sections = const [];
  bool _isLoading = false;
  bool _isSaving = false;
  String? _error;
  DateTime? _lastLoadedAt;
  bool _usingFallback = false;
  int? _sessionAccountId;
  int _authSessionEpoch = 0;
  int _sessionGeneration = 0;
  bool _hasSessionContext = false;

  WaterSectionProvider(Dio? dio)
      : _service = dio != null ? WaterSectionService(dio) : null,
        _iconReviewService =
            dio != null ? WaterSectionIconReviewService(dio) : null;

  List<WaterSection> get sections => _sections;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  String? get error => _error;
  bool get usingFallback => _usingFallback;
  DateTime? get lastLoadedAt => _lastLoadedAt;
  WaterSectionService? get service => _service;
  WaterSectionIconReviewService? get iconReviewService => _iconReviewService;

  /// 版块 DTO 含关注状态和当前用户等级，因此账号变化时不能复用旧缓存。
  void syncSessionUser(int? accountId, [int authSessionEpoch = 0]) {
    final normalizedAccountId =
        accountId != null && accountId > 0 ? accountId : null;
    if (_hasSessionContext &&
        _sessionAccountId == normalizedAccountId &&
        _authSessionEpoch == authSessionEpoch) {
      return;
    }
    _hasSessionContext = true;
    _sessionAccountId = normalizedAccountId;
    _authSessionEpoch = authSessionEpoch;
    _sessionGeneration++;
    _sections = const [];
    _isLoading = false;
    _isSaving = false;
    _error = null;
    _lastLoadedAt = null;
    _usingFallback = false;
    notifyListeners();
  }

  /// active 状态版块（接口数据或 fallback）
  List<WaterSection> get activeSections =>
      _sections.where((s) => s.status == 'active').toList();

  /// 启动加载；5 分钟缓存，forceRefresh 强制刷新。
  Future<void> loadSections({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _lastLoadedAt != null &&
        DateTime.now().difference(_lastLoadedAt!) < _cacheTtl &&
        _sections.isNotEmpty) {
      return;
    }
    if (_isLoading) return;
    final session = _captureSession();
    _isLoading = true;
    notifyListeners();
    try {
      if (_service != null) {
        final fresh = await _service!.fetchSections();
        if (!_ownsSession(session)) return;
        _sections = fresh;
        _usingFallback = false;
      } else {
        if (!_ownsSession(session)) return;
        // 无网络层（测试环境）：直接 fallback
        _sections =
            kWaterPostCategories.map(WaterSection.fromLegacyCategory).toList();
        _usingFallback = true;
      }
      _error = null;
      _lastLoadedAt = DateTime.now();
    } catch (e) {
      if (!_ownsSession(session)) return;
      // fallback：本地 taxonomy 转成 WaterSection
      _sections =
          kWaterPostCategories.map(WaterSection.fromLegacyCategory).toList();
      _usingFallback = true;
      _error = e.toString();
      debugPrint('WaterSectionProvider fallback: $_error');
    } finally {
      if (_ownsSession(session)) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 按 slug 查找；找不到返回 null。
  WaterSection? getBySlug(String slug) {
    for (final s in _sections) {
      if (s.slug == slug) return s;
    }
    return null;
  }

  /// 按 slug 查找；找不到回退到本地 taxonomy，最后兜底 campus_life
  WaterSection getBySlugOrFallback(String slug) {
    final fromRemote = getBySlug(slug);
    if (fromRemote != null) return fromRemote;
    final legacy = waterCategoryOf(slug);
    if (legacy != null) return WaterSection.fromLegacyCategory(legacy);
    // 最终兜底
    if (_sections.isNotEmpty) return _sections.first;
    final campusLife =
        kWaterPostCategories.firstWhere((c) => c.value == 'campus_life');
    return WaterSection.fromLegacyCategory(campusLife);
  }

  Future<void> refreshSections() => loadSections(forceRefresh: true);

  Future<WaterSection?> refreshSection(String slug) async {
    return _refreshSection(slug);
  }

  Future<WaterSection?> refreshSectionForManage(String slug) async {
    return _refreshSection(slug, includeDisabledTags: true);
  }

  Future<WaterSection?> _refreshSection(
    String slug, {
    bool includeDisabledTags = false,
  }) async {
    if (_service == null) return getBySlug(slug);
    final session = _captureSession();
    try {
      final fresh = await _service!.fetchSection(
        slug,
        includeDisabledTags: includeDisabledTags,
      );
      if (!_ownsSession(session)) return null;
      _upsertSection(fresh);
      _error = null;
      notifyListeners();
      return fresh;
    } catch (e) {
      if (!_ownsSession(session)) return null;
      _error = _mapError(e);
      notifyListeners();
      return getBySlug(slug);
    }
  }

  Future<bool> updateSectionDisplay({
    required String slug,
    required Map<String, dynamic> fields,
  }) async {
    return _save((session) async {
      final fresh = await _service!.updateSectionDisplay(
        slug: slug,
        fields: fields,
      );
      if (!_ownsSession(session)) return;
      _upsertSection(fresh);
    });
  }

  Future<bool> createTag({
    required String sectionSlug,
    required Map<String, dynamic> fields,
    bool includeDisabledTags = false,
  }) async {
    return _save((session) async {
      await _service!.createTag(sectionSlug: sectionSlug, fields: fields);
      await _refreshSectionAfterMutation(
        sectionSlug,
        session: session,
        includeDisabledTags: includeDisabledTags,
      );
    });
  }

  Future<bool> updateTag({
    required String sectionSlug,
    required int tagId,
    required Map<String, dynamic> fields,
    bool includeDisabledTags = false,
  }) async {
    return _save((session) async {
      await _service!.updateTag(
        sectionSlug: sectionSlug,
        tagId: tagId,
        fields: fields,
      );
      await _refreshSectionAfterMutation(
        sectionSlug,
        session: session,
        includeDisabledTags: includeDisabledTags,
      );
    });
  }

  Future<bool> enableTag({
    required String sectionSlug,
    required int tagId,
    String? reason,
    bool includeDisabledTags = false,
  }) {
    return updateTagStatus(
      sectionSlug: sectionSlug,
      tagId: tagId,
      isEnabled: true,
      reason: reason,
      includeDisabledTags: includeDisabledTags,
    );
  }

  Future<bool> disableTag({
    required String sectionSlug,
    required int tagId,
    String? reason,
    bool includeDisabledTags = false,
  }) {
    return updateTagStatus(
      sectionSlug: sectionSlug,
      tagId: tagId,
      isEnabled: false,
      reason: reason,
      includeDisabledTags: includeDisabledTags,
    );
  }

  Future<bool> updateTagStatus({
    required String sectionSlug,
    required int tagId,
    required bool isEnabled,
    String? reason,
    bool includeDisabledTags = false,
  }) async {
    return _save((session) async {
      await _service!.updateTagStatus(
        sectionSlug: sectionSlug,
        tagId: tagId,
        isEnabled: isEnabled,
        reason: reason,
      );
      await _refreshSectionAfterMutation(
        sectionSlug,
        session: session,
        includeDisabledTags: includeDisabledTags,
      );
    });
  }

  Future<bool> toggleFollow(String slug, bool follow) async {
    if (_service == null) return false;
    return _save((session) async {
      if (follow) {
        await _service!.followSection(slug);
      } else {
        await _service!.unfollowSection(slug);
      }
      if (!_ownsSession(session)) return;
      await _refreshSectionAfterMutation(slug, session: session);
    });
  }

  Future<bool> _save(
    Future<void> Function(_WaterSectionSession session) action,
  ) async {
    final session = _captureSession();
    if (_service == null) {
      if (_ownsSession(session)) {
        _error = '网络异常，请稍后重试';
        notifyListeners();
      }
      return false;
    }
    _isSaving = true;
    _error = null;
    notifyListeners();
    try {
      await action(session);
      if (!_ownsSession(session)) return false;
      _error = null;
      return true;
    } catch (e) {
      if (!_ownsSession(session)) return false;
      _error = _mapError(e);
      return false;
    } finally {
      if (_ownsSession(session)) {
        _isSaving = false;
        notifyListeners();
      }
    }
  }

  Future<void> _refreshSectionAfterMutation(
    String slug, {
    required _WaterSectionSession session,
    bool includeDisabledTags = false,
  }) async {
    final fresh = await _service!.fetchSection(
      slug,
      includeDisabledTags: includeDisabledTags,
    );
    if (!_ownsSession(session)) return;
    _upsertSection(fresh);
  }

  _WaterSectionSession _captureSession() => _WaterSectionSession(
        generation: _sessionGeneration,
        accountId: _sessionAccountId,
        authSessionEpoch: _authSessionEpoch,
      );

  bool _ownsSession(_WaterSectionSession session) {
    return session.generation == _sessionGeneration &&
        session.accountId == _sessionAccountId &&
        session.authSessionEpoch == _authSessionEpoch;
  }

  void _upsertSection(WaterSection section) {
    final next = [..._sections];
    final index = next.indexWhere((s) => s.slug == section.slug);
    if (index >= 0) {
      next[index] = section;
    } else {
      next.add(section);
    }
    next.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    _sections = next;
    _usingFallback = false;
    _lastLoadedAt = DateTime.now();
  }

  String _mapError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      String? message;
      if (data is Map) {
        message = '${data['message'] ?? data['error'] ?? ''}'.trim();
      }
      if (status == 403) return '没有该操作权限';
      if (status == 400 && message != null && message.isNotEmpty) {
        return message;
      }
      if (status == 409 && message != null && message.isNotEmpty) {
        return message;
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.connectionError) {
        return '网络异常，请稍后重试';
      }
    }
    return '操作失败，请稍后重试';
  }
}

class _WaterSectionSession {
  const _WaterSectionSession({
    required this.generation,
    required this.accountId,
    required this.authSessionEpoch,
  });

  final int generation;
  final int? accountId;
  final int authSessionEpoch;
}
