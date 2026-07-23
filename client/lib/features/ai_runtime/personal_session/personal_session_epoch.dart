class PersonalRequestEpoch {
  const PersonalRequestEpoch({
    required this.accountKey,
    required this.generation,
  });

  final String accountKey;
  final int generation;
}

/// 管理个人助手页面的账号代际和当前请求所有权。
class PersonalSessionEpoch {
  String? _accountKey;
  int _generation = 0;
  String? _activeRequestId;

  String? get accountKey => _accountKey;
  int get generation => _generation;
  String? get activeRequestId => _activeRequestId;

  bool synchronizeAccount(String accountKey) {
    if (_accountKey == null) {
      _accountKey = accountKey;
      return false;
    }
    if (_accountKey == accountKey) return false;
    _accountKey = accountKey;
    _generation++;
    _activeRequestId = null;
    return true;
  }

  PersonalRequestEpoch capture() => PersonalRequestEpoch(
        accountKey: _accountKey ?? '',
        generation: _generation,
      );

  bool isCurrent(PersonalRequestEpoch request) =>
      request.accountKey == _accountKey && request.generation == _generation;

  bool activate(PersonalRequestEpoch request, String requestId) {
    if (!isCurrent(request)) return false;
    _activeRequestId = requestId;
    return true;
  }

  bool owns(PersonalRequestEpoch request, String requestId) =>
      isCurrent(request) && _activeRequestId == requestId;

  bool release(PersonalRequestEpoch request, String requestId) {
    if (!owns(request, requestId)) return false;
    _activeRequestId = null;
    return true;
  }

  void invalidate() {
    _generation++;
    _activeRequestId = null;
  }
}
