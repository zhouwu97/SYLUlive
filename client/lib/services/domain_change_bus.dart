import 'package:flutter/foundation.dart';

enum DomainChange {
  competitionPlan,
  userCalendar,
  reminder,
  academic,
  schedule,
}

/// 跨页面的细粒度变更通知；页面只刷新自己关心的域，不触发全 App 重建。
class DomainChangeBus extends ChangeNotifier {
  DomainChangeBus._();

  static final DomainChangeBus instance = DomainChangeBus._();

  final Map<DomainChange, int> _revisions = <DomainChange, int>{};
  DomainChange? _lastChange;

  DomainChange? get lastChange => _lastChange;

  int revisionOf(DomainChange change) => _revisions[change] ?? 0;

  void emit(DomainChange change) {
    _lastChange = change;
    _revisions[change] = revisionOf(change) + 1;
    notifyListeners();
  }
}
