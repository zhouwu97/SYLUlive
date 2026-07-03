import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../config/water_post_taxonomy.dart';
import '../models/water_section.dart';
import '../services/water_section_service.dart';

/// 管理水帖版块的缓存与 fallback。
/// 接口失败时使用 kWaterPostCategories 转出的 fallback 版块，保证离线可用。
class WaterSectionProvider extends ChangeNotifier {
  static const _cacheTtl = Duration(minutes: 5);

final WaterSectionService? _service;

  List<WaterSection> _sections = const [];
  bool _isLoading = false;
  String? _error;
  DateTime? _lastLoadedAt;
  bool _usingFallback = false;

  WaterSectionProvider(Dio? dio)
      : _service = dio != null ? WaterSectionService(dio) : null;

  List<WaterSection> get sections => _sections;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get usingFallback => _usingFallback;
  DateTime? get lastLoadedAt => _lastLoadedAt;

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
    _isLoading = true;
    notifyListeners();
    try {
      if (_service != null) {
        final fresh = await _service!.fetchSections();
        _sections = fresh;
        _usingFallback = false;
      } else {
        // 无网络层（测试环境）：直接 fallback
        _sections = kWaterPostCategories
            .map(WaterSection.fromLegacyCategory)
            .toList();
        _usingFallback = true;
      }
      _error = null;
      _lastLoadedAt = DateTime.now();
    } catch (e) {
      // fallback：本地 taxonomy 转成 WaterSection
      _sections = kWaterPostCategories
          .map(WaterSection.fromLegacyCategory)
          .toList();
      _usingFallback = true;
      _error = e.toString();
      debugPrint('WaterSectionProvider fallback: $_error');
    } finally {
      _isLoading = false;
      notifyListeners();
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
}