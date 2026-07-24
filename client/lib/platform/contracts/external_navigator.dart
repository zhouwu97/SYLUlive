abstract interface class ExternalNavigator {
  static ExternalNavigator? _instance;

  static void register(ExternalNavigator instance) {
    _instance = instance;
  }

  static ExternalNavigator current() {
    if (_instance != null) return _instance!;
    _instance = const UnsupportedExternalNavigator();
    return _instance!;
  }

  Future<bool> open(Uri uri);
}

class UnsupportedExternalNavigator implements ExternalNavigator {
  const UnsupportedExternalNavigator();
  @override
  Future<bool> open(Uri uri) async => false;
}
