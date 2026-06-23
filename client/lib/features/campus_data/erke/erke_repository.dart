import '../../../services/webvpn_service.dart';
import '../storage/erke_cache_store.dart';
import 'erke_client.dart';
import 'erke_models.dart';

/// 二课数据仓库
///
/// 用法:
///   final repo = ErkeRepository(vpnService: _vpn, cacheStore: _cache);
///   await repo.loadCache(); // 读取本地缓存
///   if (!repo.hasLiveSession) { await repo.loginAndFetch(...); }
class ErkeRepository {
  final WebVpnService _vpn;
  final ErkeCacheStore _cache;

  ErkeClient? _client;

  /// 本地是否有数据（缓存命中，含旧缓存迁移）
  bool hasData = false;

  /// 当前是否持有在线二课会话（_client != null && 已成功 loginToErke）
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

  /// 加载缓存（不发起网络请求）
  /// 优先读取新 snapshot；不存在时从旧 SharedPreferences 键迁移
  Future<void> loadCache() async {
    final snapshot = await _cache.loadOrMigrateSnapshot();
    if (snapshot == null) return;

    graduation = snapshot.graduation;
    yearly = snapshot.yearly;
    activities = snapshot.activities;
    activitiesByYear = snapshot.activitiesByYear;
    availableYears = snapshot.yearly?.availableYears ?? [];
    hasData = snapshot.hasActivities || snapshot.hasGraduationData;
    // 缓存命中不代表有在线会话 — 切换学年需要重新验证
    hasLiveSession = false;
  }

  // ================================================================
  //  登录 + 完整抓取
  // ================================================================

  Future<void> loginAndFetch(
    String studentId,
    String casPassword,
    String erkePassword,
  ) async {
    fetchError = null;

    try {
      // 1. WebVPN 登录
      final vpnOk = await _vpn.login(studentId, casPassword);
      if (!vpnOk) {
        fetchError = '统一认证登录失败，请检查密码';
        return;
      }

      // 2. 创建 ErkeClient (复用 VPN 的 dio)
      _client = ErkeClient(dio: _vpn.dio);

      // 3. 二课登录
      await _client!.loginToErke(studentId, erkePassword);
      hasLiveSession = true;

      // 4. 并行获取三页数据
      final results = await Future.wait([
        _client!.getGraduationSummary(),
        _client!.getYearlySummary(),
        _client!.getActivities(),
      ]);

      graduation = results[0] as ErkeGraduationSummary;
      yearly = results[1] as ErkeYearlySummary;
      activities = results[2] as List<ErkeActivity>;
      activitiesByYear = {yearly!.year: activities};
      availableYears = yearly!.availableYears;
      hasData = true;

      // 5. 写入缓存
      await _cache.saveFullResult(
        graduation: graduation!,
        yearly: yearly!,
        activities: activities,
      );
    } catch (e) {
      fetchError = e.toString();
      rethrow;
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
      // 检查缓存
      final cached = await _cache.loadOrMigrateSnapshot();
      if (cached != null &&
          cached.yearlyByYear.containsKey(year) &&
          cached.activitiesByYear.containsKey(year)) {
        yearly = cached.yearlyByYear[year];
        activities = cached.activitiesByYear[year]!;
        isYearlyLoading = false;
        return;
      }

      // 网络请求 — 学年汇总和活动一起请求
      final results = await Future.wait([
        _client!.getYearlySummary(year: year),
        _client!.getActivities(year: year),
      ]);

      final newYearly = results[0] as ErkeYearlySummary;
      final yearActivities = results[1] as List<ErkeActivity>;

      yearly = newYearly;
      activities = yearActivities;
      activitiesByYear[year] = yearActivities;

      // 写入缓存
      await _cache.saveYearlySummary(newYearly, yearActivities);
    } catch (e) {
      yearlyError = e.toString();
    } finally {
      isYearlyLoading = false;
    }
  }

  // ================================================================
  //  清理
  // ================================================================

  Future<void> clearAll() async {
    await _cache.clearAll();
    graduation = null;
    yearly = null;
    activities = [];
    activitiesByYear = {};
    availableYears = [];
    hasData = false;
    hasLiveSession = false;
    _client = null;
    fetchError = null;
    yearlyError = null;
  }
}
