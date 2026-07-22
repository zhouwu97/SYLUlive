import 'package:shared_preferences/shared_preferences.dart';
import '../platform/contracts/secure_store.dart';

/// 保存体测密码，并将旧版 SharedPreferences 明文凭证一次性迁移出去。
class PhysicalCredentialStore {
  PhysicalCredentialStore({
    AppSecretStore? secureStore,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : _secureStore = secureStore ?? AppSecretStore.current(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final AppSecretStore _secureStore;
  final Future<SharedPreferences> Function() _preferencesLoader;

  static const String _securePrefix = 'secure_physical_test_pwd_';
  static const String _legacyPrefix = 'sylu_physical_test_pwd_';

  String _secureKey(String username) => '$_securePrefix$username';
  String _legacyKey(String username) => '$_legacyPrefix$username';

  Future<String?> read(String username) async {
    final secureKey = _secureKey(username);
    final saved = await _secureStore.read(secureKey);
    if (saved != null && saved.isNotEmpty) return saved;

    final preferences = await _preferencesLoader();
    final legacyKey = _legacyKey(username);
    final legacy = preferences.getString(legacyKey);
    if (legacy == null || legacy.isEmpty) return null;

    // 只有安全写入成功后才删除旧明文，避免迁移异常导致用户凭证丢失。
    await _secureStore.write(secureKey, legacy);
    await preferences.remove(legacyKey);
    return legacy;
  }

  Future<void> write(String username, String password) async {
    await _secureStore.write(_secureKey(username), password);
    final preferences = await _preferencesLoader();
    await preferences.remove(_legacyKey(username));
  }

  Future<void> delete(String username) async {
    await _secureStore.delete(_secureKey(username));
    final preferences = await _preferencesLoader();
    await preferences.remove(_legacyKey(username));
  }
}
