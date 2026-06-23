import 'package:flutter/foundation.dart';

import '../../../services/webvpn_service.dart';
import '../storage/erke_cache_store.dart';
import 'erke_client.dart';
import 'erke_models.dart';

class ErkeRepository {
  final WebVpnService _vpn;
  final ErkeCacheStore _cache;

  ErkeClient? _client;

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

  ErkeRepository({
    required WebVpnService vpnService,
    required ErkeCacheStore cacheStore,
  })  : _vpn = vpnService,
        _cache = cacheStore;

  // ================================================================
  //  缓存
  // ================================================================

  Future<bool> hasCache() => _cache.hasCache();

  Future<void> loadCache() async {
    final snapshot = await _cache.loadOrMigrateSnapshot();
    if (snapshot == null) return;

    graduation = snapshot.graduation;
    yearly = snapshot.yearly;
    activities = snapshot.activities;
    activitiesByYear = snapshot.activitiesByYear;
    availableYears = snapshot.yearly?.availableYears ?? [];
    hasCachedData = snapshot.hasActivities || snapshot.hasGraduationData;
    hasLiveSession = false;
  }

  // ================================================================
  //  登录 + 完整抓取 → 返回 bool
  // ================================================================

  Future<bool> loginAndFetch(
    String studentId,
    String casPassword,
    String erkePassword,
  ) async {
    fetchError = null;
    String phase = 'init';

    // 提前声明，以便 catch 块在部分成功时保存已获取数据
    ErkeGraduationSummary? partialGraduation;
    List<ErkeActivity> partialActivities = [];

    try {
      // 1. WebVPN 登录
      phase = 'vpn_login';
      debugPrint('[Erke] phase=$phase start');
      final vpnOk = await _vpn.login(studentId, casPassword);
      if (!vpnOk) {
        fetchError = '统一认证登录失败，请检查密码';
        debugPrint(
            '[Erke] phase=$phase failed type=VpnLoginFailed message=$fetchError');
        hasLiveSession = false;
        _client = null;
        return false;
      }
      debugPrint('[Erke] phase=$phase success');

      // 2. 二课登录
      phase = 'erke_login';
      debugPrint('[Erke] phase=$phase start');
      _client = ErkeClient(dio: _vpn.dio);
      await _client!.loginToErke(studentId, erkePassword);
      hasLiveSession = true;
      debugPrint('[Erke] phase=$phase success');

      // 3. 毕业要求
      phase = 'graduation_fetch';
      debugPrint('[Erke] phase=$phase start');
      try {
        partialGraduation = await _client!.getGraduationSummary();
        debugPrint('[Erke] phase=$phase success');
      } catch (e, st) {
        debugPrint(
            '[Erke] phase=$phase failed type=${e.runtimeType} message=$e');
        debugPrintStack(label: '[Erke] $phase', stackTrace: st);
        rethrow;
      }

      // 4. 学年要求
      phase = 'yearly_fetch';
      debugPrint('[Erke] phase=$phase start');
      ErkeYearlySummary? newYearly;
      try {
        newYearly = await _client!.getYearlySummary();
        debugPrint('[Erke] phase=$phase success');
      } catch (e, st) {
        debugPrint(
            '[Erke] phase=$phase failed type=${e.runtimeType} message=$e');
        debugPrintStack(label: '[Erke] $phase', stackTrace: st);
        rethrow;
      }

      // 5. 活动明细
      phase = 'activities_fetch';
      debugPrint('[Erke] phase=$phase start');
      try {
        partialActivities = await _client!.getActivities();
        debugPrint('[Erke] phase=$phase success');
      } catch (e, st) {
        debugPrint(
            '[Erke] phase=$phase failed type=${e.runtimeType} message=$e');
        debugPrintStack(label: '[Erke] $phase', stackTrace: st);
        rethrow;
      }

      // 全部成功 → 更新内存 + 写缓存
      graduation = partialGraduation;
      yearly = newYearly;
      activities = partialActivities;
      activitiesByYear = {newYearly.year: partialActivities};
      availableYears = newYearly.availableYears;
      hasCachedData = true;

      phase = 'cache_save';
      debugPrint('[Erke] phase=$phase start');
      await _cache.saveFullResult(
        graduation: graduation!,
        yearly: yearly!,
        activities: activities,
      );
      debugPrint('[Erke] phase=$phase success');

      fetchError = null;
      return true;
    } catch (e, stackTrace) {
      fetchError =
          '[Erke] phase=$phase failed type=${e.runtimeType} message=$e';
      debugPrint(fetchError);
      debugPrintStack(label: '[Erke] $phase stack', stackTrace: stackTrace);

      // 毕业和活动成功 → 保存到内存，不让学年失败拖垮毕业页
      if (partialGraduation != null && partialActivities.isNotEmpty) {
        graduation = partialGraduation;
        activities = partialActivities;
        hasCachedData = true;
        // 异步写缓存
        _cache.saveActivities(partialActivities).catchError((_) {});
        debugPrint(
            '[Erke] partial save: graduation+activities (yearly failed)');
      }

      // 学年失败但登录成功 → 保留 session 供单独重试
      if (phase == 'yearly_fetch' && _client != null) {
        hasLiveSession = true;
        debugPrint('[Erke] session kept alive for yearly retry');
      } else {
        hasLiveSession = false;
        _client = null;
      }

      return false;
    }
  }

  // ================================================================
  //  学年切换
  // ================================================================

  Future<void> fetchYearlySummary(String year) async {
    if (!hasLiveSession || _client == null) {
      yearlyError = '会话已过期，请重新登录';
      return;
    }

    isYearlyLoading = true;
    yearlyError = null;

    try {
      final cached = await _cache.loadOrMigrateSnapshot();
      if (cached != null &&
          cached.yearlyByYear.containsKey(year) &&
          cached.activitiesByYear.containsKey(year)) {
        yearly = cached.yearlyByYear[year];
        activities = cached.activitiesByYear[year]!;
        isYearlyLoading = false;
        return;
      }

      final results = await Future.wait([
        _client!.getYearlySummary(year: year),
        _client!.getActivities(year: year),
      ]);

      final newYearly = results[0] as ErkeYearlySummary;
      final yearActivities = results[1] as List<ErkeActivity>;

      yearly = newYearly;
      activities = yearActivities;
      activitiesByYear[year] = yearActivities;

      await _cache.saveYearlySummary(newYearly, yearActivities);
    } catch (e) {
      yearlyError = e.toString();
    } finally {
      isYearlyLoading = false;
    }
  }

  // ================================================================
  //  状态重置（不删缓存）
  // ================================================================

  /// 重置在线会话，保留所有缓存数据和本地快照
  void resetLiveSession() {
    hasLiveSession = false;
    _client = null;
    fetchError = null;
    yearlyError = null;
  }

  /// 清除二课成绩缓存和数据
  Future<void> clearCachedData() async {
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
