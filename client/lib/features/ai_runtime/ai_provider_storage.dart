import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../platform/contracts/secure_store.dart';
import '../campus_data/storage/account_cache_namespace.dart';
import 'ai_endpoint_policy.dart';
import 'ai_model_provider.dart';



/// 配置和密钥分开存储，避免 SharedPreferences 备份或日志泄露 API Key。
class AIProviderSettingsStore {
  AIProviderSettingsStore({
    required String appUserId,
    String providerConfigId = 'default',
    AppSecureStore? secureStore,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : _accountHash = _accountHashFor(appUserId),
        _providerConfigId = _providerConfigIdFor(providerConfigId),
        _secureStore = secureStore ?? AppSecureStore.current(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final String _accountHash;
  final String _providerConfigId;
  final AppSecureStore _secureStore;
  final Future<SharedPreferences> Function() _preferencesLoader;

  String get _configKey =>
      'ai_provider_config/$_accountHash/$_providerConfigId';
  String get _apiKey => 'ai_provider_key/$_accountHash/$_providerConfigId';

  static String _accountHashFor(String appUserId) {
    final fingerprint = AccountCacheNamespace.fingerprint(appUserId);
    if (fingerprint.isEmpty) throw ArgumentError.value(appUserId, 'appUserId');
    return fingerprint;
  }

  static String _providerConfigIdFor(String value) {
    final normalized = value.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(normalized)) {
      throw ArgumentError.value(value, 'providerConfigId');
    }
    return normalized;
  }

  Future<AIModelProviderConfig?> readConfig() async {
    final preferences = await _preferencesLoader();
    final raw = preferences.getString(_configKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('配置格式错误');
      final config =
          AIModelProviderConfig.fromJson(Map<String, dynamic>.from(decoded));
      if (config.id != _providerConfigId) {
        throw const FormatException('配置 ID 不匹配');
      }
      return config;
    } on FormatException {
      throw const AIModelProviderException('模型配置无效，请重新配置');
    }
  }

  Future<bool> hasApiKey() async {
    final value = await _secureStore.read(_apiKey);
    return value != null && value.trim().isNotEmpty;
  }

  Future<String?> readApiKey() async {
    final value = await _secureStore.read(_apiKey);
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> saveCampusPublic() async {
    await _saveConfig(AIModelProviderConfig(
      id: _providerConfigId,
      kind: AIModelProviderKind.campusPublic,
    ));
    await _secureStore.delete(_apiKey);
  }

  Future<void> saveOpenAICompatible({
    required String endpoint,
    required String model,
    OpenAIWireApi wireApi = OpenAIWireApi.auto,
    String? apiKey,
  }) async {
    final normalizedKey = apiKey?.trim() ?? '';
    if (normalizedKey.isEmpty && !await hasApiKey()) {
      throw const AIModelProviderException('请输入 API Key');
    }
    AIEndpointPolicy.parseBaseEndpoint(endpoint);
    if (model.trim().isEmpty) {
      throw const AIModelProviderException('请先选择或填写模型名称');
    }
    final config = AIModelProviderConfig(
      id: _providerConfigId,
      kind: AIModelProviderKind.openAICompatible,
      endpoint: endpoint.trim(),
      model: model.trim(),
      wireApi: wireApi,
    );
    if (normalizedKey.isEmpty) {
      await _saveConfig(config);
      return;
    }

    final previousKey = await _secureStore.read(_apiKey);
    await _secureStore.write(_apiKey, normalizedKey);
    try {
      await _saveConfig(config);
    } catch (error, stackTrace) {
      try {
        if (previousKey == null) {
          await _secureStore.delete(_apiKey);
        } else {
          await _secureStore.write(_apiKey, previousKey);
        }
      } catch (_) {
        // 配置写入失败时优先保留原始错误；密钥仍只存在安全存储中。
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> clear() async {
    // 先删除密钥，避免普通配置已消失却留下不可见的安全存储项。
    await _secureStore.delete(_apiKey);
    final preferences = await _preferencesLoader();
    final removed = await preferences.remove(_configKey);
    if (!removed) throw StateError('删除模型配置失败');
  }

  /// 清理配置缺失时遗留在安全存储中的密钥。
  Future<void> clearApiKey() async {
    await _secureStore.delete(_apiKey);
  }

  Future<void> _saveConfig(AIModelProviderConfig config) async {
    final preferences = await _preferencesLoader();
    final saved = await preferences.setString(_configKey, jsonEncode(config));
    if (!saved) throw StateError('保存模型服务配置失败');
  }
}
