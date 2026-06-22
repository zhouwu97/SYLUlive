import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';

class CampusSecureStore {
  final FlutterSecureStorage _storage;

  CampusSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _keyWebvpnUsername = 'webvpn_username';
  static const _keyWebvpnPassword = 'webvpn_password';
  static const _keyErkePassword = 'erke_password';
  static const _keyMigrationCompleted = 'campus_credentials_migration_v1';

  Future<void> migrateOldPasswords() async {
    final migrationStatus = await _storage.read(key: _keyMigrationCompleted);
    if (migrationStatus == 'true') {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final oldCas = prefs.getString('erke_cas_pwd');
    final oldErke = prefs.getString('erke_erke_pwd');
    
    if (oldCas != null && oldCas.isNotEmpty) {
      await _storage.write(key: _keyWebvpnPassword, value: oldCas);
      // Wait for write success before removing
      final confirmed = await _storage.read(key: _keyWebvpnPassword);
      if (confirmed != oldCas) {
        throw const CampusStorageException('统一认证密码迁移验证失败');
      }
      await prefs.remove('erke_cas_pwd');
    }
    
    if (oldErke != null && oldErke.isNotEmpty) {
      await saveErkePassword(oldErke);
      final verified = await getErkePassword();
      if (verified != oldErke) {
        throw const CampusStorageException('二课密码迁移验证失败');
      }
      await prefs.remove('erke_erke_pwd');
    }

    await _storage.write(key: _keyMigrationCompleted, value: 'true');
  }

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

  Future<void> deleteWebvpnPassword() async {
    await _storage.delete(key: _keyWebvpnPassword);
  }

  Future<void> saveErkePassword(String password) async {
    await _storage.write(key: _keyErkePassword, value: password);
  }

  Future<String?> getErkePassword() async {
    return await _storage.read(key: _keyErkePassword);
  }

  Future<void> deleteErkePassword() async {
    await _storage.delete(key: _keyErkePassword);
  }

  Future<void> clearWebvpnCredentials() async {
    await _storage.delete(key: _keyWebvpnUsername);
    await _storage.delete(key: _keyWebvpnPassword);
  }
}
