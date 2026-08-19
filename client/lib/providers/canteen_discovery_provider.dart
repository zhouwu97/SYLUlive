import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/canteen_home.dart';
import '../models/canteen_ranking.dart';

/// 食堂发现页数据源（首页 + 排行）。
///
/// 与原 [CanteenProvider]（详情/评价/菜品/投稿/管理）职责分离。
/// 首页刷新采用 stale-while-refresh：已有数据时保留旧内容，仅走顶部轻量 loading，
/// 避免刷新闪白；仅首次加载展示骨架。
class CanteenDiscoveryProvider with ChangeNotifier {
  final Dio _dio;

  CanteenHomeData _home = const CanteenHomeData();
  bool _homeInitialLoading = false;
  bool _homeRefreshing = false;
  String? _homeError;

  CanteenHomeData get home => _home;
  bool get homeInitialLoading => _homeInitialLoading;
  bool get homeRefreshing => _homeRefreshing;
  String? get homeError => _homeError;

  bool get hasHomeData => _home.feed.isNotEmpty || !_home.hero.isEmpty;

  // ── 排行 ──────────────────────────────────────────────────────────
  final Map<String, List<CanteenRankingItem>> _rankings = {};
  bool _rankingLoading = false;
  String? _rankingError;
  int? _rankingTotal;
  String _rankingSort = CanteenRankingSort.composite;

  List<CanteenRankingItem> get rankingItems => _rankings[_rankingSort] ?? const [];
  bool get rankingLoading => _rankingLoading;
  String? get rankingError => _rankingError;
  int? get rankingTotal => _rankingTotal;
  String get rankingSort => _rankingSort;

  CanteenDiscoveryProvider(this._dio);

  Future<void>? _homeLoadFuture;
  Future<void>? _rankingLoadFuture;

  /// 拉取首页。已有数据时为刷新（不进入骨架）。
  Future<void> loadHome({bool forceRefresh = true}) {
    if (_homeLoadFuture != null) return _homeLoadFuture!;
    _homeLoadFuture = _loadHomeInternal().whenComplete(() => _homeLoadFuture = null);
    return _homeLoadFuture!;
  }

  Future<void> _loadHomeInternal() async {
    if (!hasHomeData) {
      _homeInitialLoading = true;
    } else {
      _homeRefreshing = true;
    }
    _homeError = null;
    notifyListeners();

    try {
      final response = await _dio.get('/canteens/home');
      if (response.statusCode == 200 && response.data is Map) {
        _home = CanteenHomeData.fromJson(
            (response.data as Map).cast<String, dynamic>());
      }
    } on DioException catch (e) {
      if (!hasHomeData) {
        _homeError = _parseError(e);
      } else {
        // 已有旧数据：静默保留旧内容，不打断阅读。
        debugPrint('home refresh failed but keeping stale data: $e');
      }
    } finally {
      _homeInitialLoading = false;
      _homeRefreshing = false;
      notifyListeners();
    }
  }

  /// 拉取指定排序的完整排行（按 sort 缓存一份）。
  Future<void> loadRanking({String sort = CanteenRankingSort.composite}) async {
    _rankingSort = sort;
    if (_rankings.containsKey(sort)) {
      notifyListeners();
      return;
    }
    if (_rankingLoadFuture != null) {
      await _rankingLoadFuture;
      if (_rankings.containsKey(sort)) return;
    }
    _rankingLoadFuture = _loadRankingInternal(sort);
    await _rankingLoadFuture;
    _rankingLoadFuture = null;
  }

  Future<void> _loadRankingInternal(String sort) async {
    _rankingLoading = true;
    _rankingError = null;
    notifyListeners();
    try {
      final response = await _dio.get('/canteens/rankings',
          queryParameters: {'sort': sort});
      if (response.statusCode == 200 && response.data is Map) {
        final data = (response.data as Map).cast<String, dynamic>();
        final rawItems = data['items'];
        if (rawItems is List) {
          _rankings[sort] = rawItems
              .whereType<Map<String, dynamic>>()
              .map(CanteenRankingItem.fromJson)
              .toList();
        }
        final meta = data['meta'];
        if (meta is Map) {
          _rankingTotal = (meta['total'] ?? _rankings[sort]?.length).toInt();
        }
      }
    } on DioException catch (e) {
      _rankingError = _parseError(e);
      debugPrint('Error loading canteen ranking: $e');
    } finally {
      _rankingLoading = false;
      notifyListeners();
    }
  }

  /// 变更后主动失效：让下次拉取拿到新数据。
  void invalidateRanking() {
    _rankings.clear();
  }

  String _parseError(DioException e) {
    if (e.response?.data is Map && e.response?.data['error'] != null) {
      return e.response!.data['error'].toString();
    }
    final status = e.response?.statusCode;
    if (status != null && status >= 500) {
      return '加载失败，请稍后重试';
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return '网络连接失败，请检查网络后重试';
    }
    return '加载异常，请重试';
  }
}
