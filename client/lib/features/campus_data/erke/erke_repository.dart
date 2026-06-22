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

  /// Logs into the systems and fetches the data.
  Future<void> loginAndFetch(
      String webvpnUser, String webvpnPass, String erkePass) async {
    _setLoading(true);
    _errorMsg = null;
    notifyListeners();

    try {
      // Clear sessions first
      await _session.cookieJar.clearWebvpnSession();

      // 1. WebVPN login
      await _webVpnClient.login(webvpnUser, webvpnPass);
      await _secureStore.saveWebvpnCredentials(webvpnUser, webvpnPass);

      // 2. Erke login
      await _erkeClient.login(
          webvpnUser, erkePass); // Erke username is the same

      // 3. Fetch summary
      final s = await _erkeClient.getSummary();
      await _cacheStore.saveSummary(s);

      // 4. Fetch activities
      final page = await _erkeClient.getActivitiesPage(1);

      final allActs = <ErkeActivity>[];
      final seen = <String>{};

      void addActivities(List<ErkeActivity> acts) {
        for (final act in acts) {
          final key = '\${act.name}|\${act.date}|\${act.organizer}|\${act.score}';
          if (!seen.contains(key)) {
            seen.add(key);
            allActs.add(act);
          }
        }
      }

      addActivities(page.activities);

      int totalPages = page.totalPages;
      if (totalPages > 20) {
        totalPages = 20; // Hard limit
      }

      var currentHiddenFields = page.hiddenFields;

      for (var p = 2; p <= totalPages; p++) {
        try {
          final nextPage = await _erkeClient.getActivitiesPage(p, hiddenFields: currentHiddenFields);
          addActivities(nextPage.activities);
          currentHiddenFields = nextPage.hiddenFields;
        } catch (e) {
          // If a page fails, we stop fetching but keep what we have so far
          break;
        }
      }

      await _cacheStore.saveActivities(allActs);
    } on CampusDataException catch (e) {
      _errorMsg = e.message;
    } catch (e) {
      _errorMsg = e.toString();
    } finally {
      _setLoading(false);
      notifyListeners();
    }
  }

  /// Performs a full logout
  Future<void> logout() async {
    await _session.cookieJar.clearAll();
    await _secureStore.clearWebvpnCredentials();
    await _cacheStore.clearAll();
    notifyListeners();
  }

  void _setLoading(bool val) {
    _isLoading = val;
  }
}
