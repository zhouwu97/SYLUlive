import 'package:flutter/foundation.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/common/campus_http_session.dart';
import 'package:shenliyuan/features/campus_data/common/webvpn_client.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_client.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/storage/campus_secure_store.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';

class ErkeRepository extends ChangeNotifier {
  final CampusHttpSession _session;
  final CampusSecureStore _secureStore;
  final ErkeCacheStore _cacheStore;

  late final WebVpnClient _webVpnClient;
  late final ErkeClient _erkeClient;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _errorMsg;
  String? get errorMsg => _errorMsg;

  ErkeRepository({
    required CampusHttpSession session,
    required CampusSecureStore secureStore,
    required ErkeCacheStore cacheStore,
  })  : _session = session,
        _secureStore = secureStore,
        _cacheStore = cacheStore {
    _webVpnClient = WebVpnClient(dio: _session.dio);
    _erkeClient = ErkeClient(webVpnClient: _webVpnClient);
  }

  ErkeSummary? get summary => _cacheStore.getSummary();
  List<ErkeActivity>? get activities => _cacheStore.getActivities();

  Future<void>? _activeRequest;

  Future<void> loginAndFetch(
      String webvpnUser, String webvpnPass, String erkePass) {
    final active = _activeRequest;
    if (active != null) {
      return active;
    }

    final request = _doLoginAndFetch(webvpnUser, webvpnPass, erkePass);
    _activeRequest = request;

    return request.whenComplete(() {
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
      }
    });
  }

  Future<void> _doLoginAndFetch(
      String webvpnUser, String webvpnPass, String erkePass) async {
    _setLoading(true);
    _errorMsg = null;
    notifyListeners();

    try {
      // Clear sessions first
      await _session.cookieJar.clearWebvpnSession();

      // 1. WebVPN login
      await _webVpnClient.login(webvpnUser, webvpnPass);

      // 2. Erke login
      await _erkeClient.login(
          webvpnUser, erkePass); // Erke username is the same

      // 3. Fetch summary
      final s = await _erkeClient.getSummary();

      // 4. Fetch activities
      final page = await _erkeClient.getActivitiesPage(1);

      final allActs = <ErkeActivity>[];
      final seen = <String>{};

      void addActivities(List<ErkeActivity> acts) {
        for (final act in acts) {
          final key = Object.hash(
            act.name.trim(),
            act.date.trim(),
            act.organizer.trim(),
            act.score,
          ).toString();
          if (!seen.contains(key)) {
            seen.add(key);
            allActs.add(act);
          }
        }
      }

      addActivities(page.activities);

      int totalPages = page.totalPages;
      const maxSafePages = 100;
      if (totalPages > maxSafePages) {
        throw ErkePageChangedException('二课活动页数异常：$totalPages');
      }

      String pageFingerprint(List<ErkeActivity> activities) {
        return activities
            .map((e) => '${e.name}|${e.date}|${e.score}|${e.organizer}')
            .join('\n');
      }

      String prevFingerprint = pageFingerprint(page.activities);
      var currentHiddenFields = page.hiddenFields;

      for (var p = 2; p <= totalPages; p++) {
        final nextPage = await _erkeClient.getActivitiesPage(p, hiddenFields: currentHiddenFields);
        
        String currFingerprint = pageFingerprint(nextPage.activities);
        if (currFingerprint == prevFingerprint && nextPage.activities.isNotEmpty) {
           throw ErkeDuplicatePageException('二课分页异常：请求第$p页，实际返回内容与上页重复');
        }
        prevFingerprint = currFingerprint;

        addActivities(nextPage.activities);
        currentHiddenFields = nextPage.hiddenFields;
      }

      // 5. Save all data atomically
      await _cacheStore.saveSnapshot(s, allActs);
    } on CampusDataException catch (e) {
      _errorMsg = e.message;
      rethrow;
    } catch (e) {
      _errorMsg = e.toString();
      rethrow;
    } finally {
      _setLoading(false);
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _session.cookieJar.clearAll();
    await _secureStore.clearWebvpnCredentials();
    await _secureStore.deleteErkePassword();
    await _cacheStore.clearAll();
    notifyListeners();
  }

  void _setLoading(bool val) {
    _isLoading = val;
  }
}
