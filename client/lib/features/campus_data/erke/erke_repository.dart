import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../../../services/webvpn_service.dart';
import '../storage/erke_cache_store.dart';
import 'erke_client.dart';
import 'erke_models.dart';
import 'erke_parser.dart';

/// 二课抓取失败的结构化分类。只有 [credentialInvalid] 有资格让调用方清除
/// 已保存密码；其余都是链路或上游问题，清密码会导致用户被误要求重输。
enum ErkeFetchFailureCategory {
  credentialInvalid,
  networkUnavailable,
  unknown,
}

class ErkeRepository {
  final WebVpnService _vpn;
  final ErkeCacheStore _cache;
  final ErkeClient Function() _createClient;
  final bool Function() _isCurrent;

  ErkeClient? _client;
  Future<bool>? _refreshing;
  int _generation = 0;
  int _yearRequest = 0;
  bool credentialsVerified = false;
  bool lastRefreshPartial = false;
  DateTime? fetchedAt;

  bool hasCachedData = false;

  bool get hasGraduationSummary => graduation != null;
  bool get hasYearlySummary => yearly != null;

  bool hasLiveSession = false;

  ErkeGraduationSummary? graduation;
  ErkeYearlySummary? yearly;
  List<ErkeActivity> activities = [];
  Map<String, List<ErkeActivity>> activitiesByYear = {};
  List<String> availableYears = [];

  bool isYearlyLoading = false;
  String? yearlyError;
  String? fetchError;
  ErkeFetchFailureCategory failureCategory = ErkeFetchFailureCategory.unknown;

  ErkeRepository({
    required WebVpnService vpnService,
    required ErkeCacheStore cacheStore,
    ErkeClient Function()? createClient,
    bool Function()? isCurrent,
  })  : _vpn = vpnService,
        _cache = cacheStore,
        _isCurrent = isCurrent ?? (() => true),
        _createClient = createClient ?? (() => ErkeClient(dio: vpnService.dio));

  // ================================================================
  //  缓存
  // ================================================================

  Future<bool> hasCache() => _cache.hasCache();

  /// 返回当前账号保险箱中的二课快照，供用户明确授权后的摘要上传使用。
  /// 调用方只能使用返回快照构造允许上传的结构化字段，不能访问加密存储实现。
  Future<ErkeSnapshot?> readSnapshotForAuthorizedUpload() =>
      _cache.loadOrMigrateSnapshot();

  Future<void> loadCache() async {
    final snapshot = await _cache.loadOrMigrateSnapshot();
    if (snapshot == null || _refreshing != null || !_isCurrent()) return;

    graduation = snapshot.graduation;
    yearly = snapshot.yearly;
    activities = snapshot.activities;
    activitiesByYear = snapshot.activitiesByYear;
    availableYears = snapshot.yearly?.availableYears ?? [];
    hasCachedData = snapshot.hasActivities ||
        snapshot.hasGraduationData ||
        snapshot.yearly != null;
    fetchedAt = snapshot.fetchedAt;
    lastRefreshPartial = snapshot.isPartial;
    fetchError = snapshot.isPartial ? '缓存包含部分未更新数据，请完整刷新后重试' : null;
    hasLiveSession = false;
  }

  // ================================================================
  //  登录 + 完整抓取 → 返回 bool
  // ================================================================

  Future<bool> loginAndFetch(
    String studentId,
    String casPassword,
    String erkePassword,
  ) {
    return _refreshing ??= _refresh(studentId, casPassword, erkePassword)
        .whenComplete(() => _refreshing = null);
  }

  Future<bool> _refresh(
      String studentId, String casPassword, String erkePassword) async {
    final generation = _generation;
    _yearRequest++;
    isYearlyLoading = false;
    bool current() => generation == _generation && _isCurrent();
    if (!current()) return false;
    fetchError = null;
    credentialsVerified = false;
    lastRefreshPartial = false;
    failureCategory = ErkeFetchFailureCategory.unknown;
    hasLiveSession = false;
    _client = null;
    if (studentId.trim() != _cache.sourceAccountId.trim()) {
      fetchError = '二课账号已切换，请重新打开页面';
      return false;
    }
    try {
      // 刷新重新认证，旧数据在成功写入前一直保留。
      final vpnOk = await _vpn.login(studentId, casPassword);
      if (!current()) return false;
      if (!vpnOk) {
        fetchError = _vpn.lastError ?? '统一认证服务暂不可用，请稍后重试';
        failureCategory = switch (_vpn.lastFailureType) {
          WebVpnLoginFailureType.invalidCredentials =>
            ErkeFetchFailureCategory.credentialInvalid,
          WebVpnLoginFailureType.unavailable =>
            ErkeFetchFailureCategory.networkUnavailable,
          _ => ErkeFetchFailureCategory.unknown,
        };
        hasLiveSession = false;
        _client = null;
        return false;
      }
      final client = _createClient();
      await client.loginToErke(studentId, erkePassword);
      if (!current()) return false;
      _client = client;
      hasLiveSession = true;
      credentialsVerified = true;

      final failed = <String>[];
      Object? lastFailure;
      Future<T?> fetch<T>(String label, Future<T> Function() request) async {
        if (!current()) return null;
        try {
          return await request();
        } catch (error) {
          lastFailure = error;
          failed.add(label);
          debugPrint('[Erke] $label failed type=${error.runtimeType}');
          return null;
        }
      }

      // 单页失败不阻断其他页面；空活动列表是有效数据。
      final newGraduation = await fetch('毕业要求', client.getGraduationSummary);
      final newYearly = await fetch('学年要求', () => client.getYearlySummary());
      final newActivities = await fetch('活动记录', () => client.getActivities());
      final yearActivities = newYearly == null
          ? null
          : await fetch(
              '学年活动', () => client.getActivities(year: newYearly.year));
      if (!current()) return false;
      if (newGraduation == null && newYearly == null && newActivities == null) {
        _setFailure(lastFailure ?? const ErkeLoginException());
        return false;
      }
      final previous = await _cache.loadOrMigrateSnapshot();
      if (!current()) return false;
      final snapshot = ErkeSnapshot(
        graduation: newGraduation ?? graduation ?? previous?.graduation,
        yearly: newYearly ?? yearly ?? previous?.yearly,
        yearlyByYear: {
          ...?previous?.yearlyByYear,
          if (newYearly != null) newYearly.year: newYearly,
        },
        activities: newActivities ?? previous?.activities ?? activities,
        activitiesByYear: {
          ...?previous?.activitiesByYear,
          ...activitiesByYear,
          if (newYearly != null && yearActivities != null)
            newYearly.year: yearActivities,
        },
        // 混合旧值时不能替整份快照续期；未知旧时间按过期处理。
        fetchedAt: failed.isEmpty
            ? DateTime.now()
            : previous?.fetchedAt ??
                fetchedAt ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        isPartial: failed.isNotEmpty,
      );
      await _cache.saveSnapshot(snapshot);
      if (!current()) return false;
      graduation = snapshot.graduation;
      yearly = snapshot.yearly;
      activities = snapshot.activities;
      activitiesByYear = snapshot.activitiesByYear;
      availableYears = snapshot.yearly?.availableYears ?? [];
      fetchedAt = snapshot.fetchedAt;
      hasCachedData = true;
      lastRefreshPartial = failed.isNotEmpty;
      fetchError =
          failed.isEmpty ? null : '${failed.join('、')}更新失败，已保留已有数据，可重试';
      return true;
    } catch (error) {
      if (!current()) return false;
      _setFailure(error);
      return false;
    }
  }

  void _setFailure(Object error) {
    debugPrint('[Erke] refresh failed type=${error.runtimeType}');
    if (error is DioException) {
      failureCategory = ErkeFetchFailureCategory.networkUnavailable;
      fetchError = '学校服务连接失败或响应超时，请检查网络后重试';
    } else if (error is ErkeLoginException) {
      fetchError = error.message;
      hasLiveSession = false;
      _client = null;
    } else if (error is ErkePageChangedException) {
      fetchError = '学校返回的二课页面异常，请稍后重试';
    } else {
      fetchError =
          credentialsVerified ? '二课数据保存失败，已有缓存已保留，请重试' : '二课登录未完成，请稍后重试';
    }
  }

  // ================================================================
  //  学年切换
  // ================================================================

  Future<void> fetchYearlySummary(String year) async {
    final generation = _generation;
    final request = ++_yearRequest;
    bool current() =>
        generation == _generation && request == _yearRequest && _isCurrent();
    isYearlyLoading = true;
    yearlyError = null;
    try {
      final refreshing = _refreshing;
      if (refreshing != null) await refreshing;
      if (!current()) return;
      // 离线学年先查缓存，不能先以 session 不存在拒绝展示。
      final cached = await _cache.loadOrMigrateSnapshot();
      if (!current()) return;
      if (cached != null &&
          cached.yearlyByYear.containsKey(year) &&
          cached.activitiesByYear.containsKey(year)) {
        yearly = cached.yearlyByYear[year];
        activitiesByYear[year] = cached.activitiesByYear[year]!;
        return;
      }
      final client = _client;
      if (!hasLiveSession || client == null) {
        yearlyError = '需要更新二课数据后查询该学年';
        return;
      }
      final results = await Future.wait([
        client.getYearlySummary(year: year),
        client.getActivities(year: year),
      ]);
      if (!current()) return;
      final newYearly = results[0] as ErkeYearlySummary;
      final yearActivities = results[1] as List<ErkeActivity>;
      await _cache.saveYearlySummary(newYearly, yearActivities);
      if (!current()) return;
      yearly = newYearly;
      activitiesByYear[year] = yearActivities;
    } catch (error) {
      if (current()) yearlyError = '学年数据更新失败，已有数据已保留，请重试';
    } finally {
      if (current()) isYearlyLoading = false;
    }
  }

  // ================================================================
  //  状态重置（不删缓存）
  // ================================================================

  /// 重置在线会话，保留所有缓存数据和本地快照
  void resetLiveSession() {
    _generation++;
    _yearRequest++;
    credentialsVerified = false;
    isYearlyLoading = false;
    hasLiveSession = false;
    _client = null;
    fetchError = null;
    yearlyError = null;
  }

  /// 清除二课成绩缓存和数据
  Future<void> clearCachedData() async {
    resetLiveSession();
    final pending = _refreshing;
    if (pending != null) await pending;
    await _cache.clearAll();
    graduation = null;
    yearly = null;
    activities = [];
    activitiesByYear = {};
    availableYears = [];
    hasCachedData = false;
    hasLiveSession = false;
    _client = null;
    fetchError = null;
    yearlyError = null;
  }
}
