import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../services/ai_assistant_service.dart';
import 'ai_model_provider.dart';
import 'ai_provider_storage.dart';
import 'campus_public_provider.dart';
import 'openai_compatible_provider.dart';

class AIModelProviderFactory {
  AIModelProviderFactory({
    required AIProviderSettingsStore settingsStore,
    required AiAssistantService campusService,
    Dio Function()? dioFactory,
  })  : _settingsStore = settingsStore,
        _campusService = campusService,
        _dioFactory = dioFactory ?? OpenAICompatibleProvider.createDio;

  final AIProviderSettingsStore _settingsStore;
  final AiAssistantService _campusService;
  final Dio Function() _dioFactory;

  Future<AIModelProvider> create(AIModelProviderConfig config) async {
    switch (config.kind) {
      case AIModelProviderKind.campusPublic:
        return CampusPublicProvider(_campusService);
      case AIModelProviderKind.openAICompatible:
        final apiKey = await _settingsStore.readApiKey();
        if (apiKey == null) {
          throw const AIModelProviderException('未找到 API Key，请在模型设置中重新保存');
        }
        return OpenAICompatibleProvider(
          config: config,
          apiKey: apiKey,
          dio: _dioFactory(),
        );
    }
  }
}

/// 普通聊天的短生命周期控制器。
///
/// 公益模式的服务端会话只由 CampusPublicProvider 持有；自定义 Provider
/// 只接收本控制器的内存消息。切换配置或账号上下文关闭时会清空两者，
/// 不会把自定义模型消息写入校园 AI 的会话接口。
class AIModelChatController extends ChangeNotifier {
  static const int _maxMessages = 20;
  static const int _maxTotalMessageCharacters = 40000;

  AIModelChatController({
    required AIProviderSettingsStore settingsStore,
    required AIModelProviderFactory providerFactory,
  })  : _settingsStore = settingsStore,
        _providerFactory = providerFactory;

  final AIProviderSettingsStore _settingsStore;
  final AIModelProviderFactory _providerFactory;
  final List<AIModelChatMessage> _messages = <AIModelChatMessage>[];

  AIModelProviderConfig? _config;
  AIModelProvider? _provider;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  int _generation = 0;
  bool _disposed = false;

  List<AIModelChatMessage> get messages => List.unmodifiable(_messages);
  AIModelProviderConfig? get config => _config;
  bool get loading => _loading;
  bool get sending => _sending;
  String? get error => _error;
  bool get isConfigured => _config != null;

  Future<void> load() async {
    final previousProvider = _discardContext();
    final generation = _generation;
    _loading = true;
    _notify();
    unawaited(_cancelProviderBestEffort(previousProvider));
    try {
      final config = await _settingsStore.readConfig();
      if (generation != _generation) return;
      AIModelProvider? provider;
      if (config != null) {
        provider = await _providerFactory.create(config);
        if (generation != _generation) {
          unawaited(_cancelProviderBestEffort(provider));
          return;
        }
      }
      _config = config;
      _provider = provider;
    } on AIModelProviderException catch (error) {
      if (generation == _generation) {
        _config = null;
        _error = error.message;
      }
    } catch (_) {
      if (generation == _generation) {
        _config = null;
        _error = '读取模型设置失败';
      }
    } finally {
      if (generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<AIModelCapabilities?> discoverCapabilities() async {
    final provider = _provider;
    if (provider == null) return null;
    _error = null;
    _notify();
    try {
      return await provider.discoverCapabilities();
    } on AIModelProviderException catch (error) {
      _error = error.message;
    } catch (_) {
      _error = '无法读取模型能力';
    }
    _notify();
    return null;
  }

  Future<void> send(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || _sending) return;
    final provider = _provider;
    if (provider == null) {
      _error = '请先完成模型设置';
      _notify();
      return;
    }
    if (message.length > 8000) {
      _error = '单条消息不能超过 8000 个字符';
      _notify();
      return;
    }

    final generation = _generation;
    _messages.add(AIModelChatMessage(
      role: AIModelMessageRole.user,
      content: message,
    ));
    _trimMessages();
    _sending = true;
    _error = null;
    _notify();
    try {
      final result = await provider.complete(List.unmodifiable(_messages));
      if (generation != _generation) return;
      _messages.add(AIModelChatMessage(
        role: AIModelMessageRole.assistant,
        content: result.content,
      ));
      _trimMessages();
    } on AIModelProviderException catch (error) {
      if (generation == _generation) _error = error.message;
    } catch (_) {
      if (generation == _generation) _error = '普通聊天请求失败，请稍后重试';
    } finally {
      if (generation == _generation) {
        _sending = false;
        _notify();
      }
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  Future<void> closeAccountContext() async {
    final previousProvider = _discardContext();
    await _cancelProviderBestEffort(previousProvider);
  }

  AIModelProvider? _discardContext() {
    _generation++;
    final previousProvider = _provider;
    _messages.clear();
    _provider = null;
    _config = null;
    _loading = false;
    _sending = false;
    _error = null;
    _notify();
    return previousProvider;
  }

  Future<void> _cancelProviderBestEffort(AIModelProvider? provider) async {
    if (provider == null) return;
    try {
      await provider.cancelActiveRequest();
    } catch (_) {
      // 本地上下文已关闭，取消失败不能恢复旧请求。
    }
  }

  void _trimMessages() {
    var totalCharacters =
        _messages.fold<int>(0, (sum, message) => sum + message.content.length);
    while (_messages.length > _maxMessages ||
        totalCharacters > _maxTotalMessageCharacters) {
      totalCharacters -= _messages.removeAt(0).content.length;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final previousProvider = _discardContext();
    unawaited(_cancelProviderBestEffort(previousProvider));
    super.dispose();
  }
}
