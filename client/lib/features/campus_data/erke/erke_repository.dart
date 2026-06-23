import '../../../services/webvpn_service.dart';
import '../storage/erke_cache_store.dart';
import 'erke_client.dart';
import 'erke_models.dart';

/// 二课数据仓库 — 统一编排 VPN 登录、二课登录、页面抓取和缓存
///
/// 用法:
///   final repo = ErkeRepository(vpnService: _vpn, cacheStore: _cache);
///   await repo.loginAndFetch(studentId, casPwd, erkePwd);
///   // 然后使用 repo.graduation / repo.yearly / repo.activities
class ErkeRepository {
  final WebVpnService _vpn;
  final ErkeCacheStore _cache;

  ErkeClient? _client;
  bool _isLoggedIn = false;

  ErkeGraduationSummary? graduation;
  ErkeYearlySummary? yearly;
  List<ErkeActivity> activities = [];
  List<String> availableYears = [];

  bool isYearlyLoading = false;
  String? yearlyError;
  String? fetchError;

  ErkeRepository({
    required WebVpnService vpnService,
    required ErkeCacheStore cacheStore,
  })  : _vpn = vpnService,
        _cache = cacheStore;

  /// 是否已登录二课系统
  bool get isLoggedIn => _isLoggedIn;

  /// 是否有缓存数据
  Future<bool> hasCache() => _cache.hasCache();

  /// 加载缓存（不发起网络请求）
  Future<void> loadCache() async {
    final snapshot = await _cache.loadSnapshot();
    if (snapshot == null) return;

    graduation = snapshot.graduation;
    yearly = snapshot.yearly;
    activities = snapshot.activities;
    availableYears = snapshot.yearly?.availableYears ?? [];
    _isLoggedIn = snapshot.hasActivities; // 有数据视为之前登录过
  }

  /// 完整的登录+抓取流程 (首次或重新拉取)
  Future<void> loginAndFetch(
    String studentId,
    String casPassword,
    String erkePassword,
  ) async {
    fetchError = null;

    try {
      // 1. WebVPN 登录 (复用现有服务)
      final vpnOk = await _vpn.login(studentId, casPassword);
      if (!vpnOk) {
        fetchError = '统一认证登录失败，请检查密码';
        return;
      }

      // 2. 创建 ErkeClient (复用 VPN 的 dio/cookieJar)
      _client = ErkeClient(dio: _vpn.dio);

      // 3. 二课登录
      await _client!.loginToErke(studentId, erkePassword);

      // 4. 并行获取三页数据
      final results = await Future.wait([
        _client!.getGraduationSummary(),
        _client!.getYearlySummary(),
        _client!.getActivities(),
      ]);

      graduation = results[0] as ErkeGraduationSummary;
      yearly = results[1] as ErkeYearlySummary;
      activities = results[2] as List<ErkeActivity>;
      availableYears = yearly!.availableYears;

      _isLoggedIn = true;

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

  /// 切换学年 (仅重新请求学年页 + 筛选活动，不重新登录)
  Future<void> fetchYearlySummary(String year) async {
    if (_client == null || !_isLoggedIn) {
      yearlyError = '尚未登录二课系统';
      return;
    }

    isYearlyLoading = true;
    yearlyError = null;

    try {
      // 检查缓存
      final cached = await _cache.loadYearlyForYear(year);
      if (cached != null) {
        yearly = cached;
        // 也获取对应学年的活动
        activities = await _client!.getActivities(year: year);
        isYearlyLoading = false;
        return;
      }

      // 网络请求
      final newYearly = await _client!.getYearlySummary(year: year);
      yearly = newYearly;

      // 筛选活动
      activities = await _client!.getActivities(year: year);

      // 写入缓存
      await _cache.saveYearlySummary(newYearly);
    } catch (e) {
      yearlyError = e.toString();
      // 不覆盖现有数据
    } finally {
      isYearlyLoading = false;
    }
  }

  /// 清除缓存和登录态
  Future<void> clearAll() async {
    await _cache.clearAll();
    graduation = null;
    yearly = null;
    activities = [];
    availableYears = [];
    _isLoggedIn = false;
    _client = null;
    fetchError = null;
    yearlyError = null;
  }
}
