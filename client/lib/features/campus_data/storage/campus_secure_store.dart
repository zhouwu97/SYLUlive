import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CampusSecureStore {
  final FlutterSecureStorage _storage;

  CampusSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _keyWebvpnUsername = 'webvpn_username';
  static const _keyWebvpnPassword = 'webvpn_password';
  
  // Note: Erke credentials are NOT saved according to the new plan.
  // Erke uses SSO/Cookie復用, no need to store Erke password anymore.
  // "不再保存校园密码" mostly applies to the legacy way, but we still need WebVPN credentials
  // to auto-login. Actually, if we use pure SSO, maybe WebVPN password is the only one we need.

  Future<void> saveWebvpnCredentials(String username, String password) async {
    await _storage.write(key: _keyWebvpnUsername, value: username);
    await _storage.write(key: _keyWebvpnPassword, value: password);
  }

  Future<String?> getWebvpnUsername() async {
    return await _storage.read(key: _keyWebvpnUsername);
  }

  Future<String?> getWebvpnPassword() async {
    return await _storage.read(key: _keyWebvpnPassword);
  }

  Future<void> clearWebvpnCredentials() async {
    await _storage.delete(key: _keyWebvpnUsername);
    await _storage.delete(key: _keyWebvpnPassword);
  }
}
