import 'package:flutter/foundation.dart';

import '../models/campus_calendar.dart';
import '../services/campus_calendar_service.dart';

/// 校历状态管理。优先展示本地结果，再静默拉取服务端的已发布版本。
class CampusCalendarProvider extends ChangeNotifier {
  CampusCalendarProvider(this._service);

  final CampusCalendarService _service;
  CampusCalendar? _calendar;
  bool _isLoading = false;
  String? _error;

  CampusCalendar? get calendar => _calendar;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    notifyListeners();

    try {
      final cached = await _service.loadCached();
      _calendar = cached ?? await _service.loadFallback();
      notifyListeners();

      try {
        final remote = await _service.fetchCurrent();
        if (remote != null &&
            (cached == null || shouldReplaceCalendar(remote, _calendar!))) {
          _calendar = remote;
          await _service.saveCached(remote);
          notifyListeners();
        }
      } catch (_) {
        // 保留已经显示的缓存或内置校历，网络异常不阻断页面。
      }
    } catch (_) {
      _error = '校历暂不可用';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

/// 校历按学年、架构版本、内容修订号和版本号综合比较，避免跨学年数字回退。
bool shouldReplaceCalendar(CampusCalendar remote, CampusCalendar local) {
  if (remote.academicYear != local.academicYear ||
      remote.schemaVersion != local.schemaVersion) {
    return true;
  }
  if (remote.version != local.version) {
    return remote.version > local.version;
  }
  return remote.revision.isNotEmpty && remote.revision != local.revision;
}
