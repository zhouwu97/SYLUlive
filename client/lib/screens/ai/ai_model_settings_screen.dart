import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/ai_runtime/ai_endpoint_policy.dart';
import '../../features/ai_runtime/ai_model_provider.dart';
import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../features/ai_runtime/openai_compatible_provider.dart';
import '../../features/ai_runtime/tool_calling/openai_tool_calling_model.dart';
import '../../widgets/app_page_app_bar.dart';
import '../../widgets/campus/campus_theme.dart';

typedef AIModelDiscovery = Future<AIModelCapabilities> Function(
  AIModelProviderConfig config,
  String apiKey,
);
typedef AIToolCallingProbe = Future<void> Function(
  AIModelProviderConfig config,
  String apiKey,
);

class AIModelSettingsScreen extends StatefulWidget {
  const AIModelSettingsScreen({
    super.key,
    required this.appUserId,
    this.settingsStore,
    this.modelDiscovery,
    this.toolCallingProbe,
  });

  final String appUserId;
  final AIProviderSettingsStore? settingsStore;
  final AIModelDiscovery? modelDiscovery;
  final AIToolCallingProbe? toolCallingProbe;

  @override
  State<AIModelSettingsScreen> createState() => _AIModelSettingsScreenState();
}

class _AIModelSettingsScreenState extends State<AIModelSettingsScreen> {
  late final AIProviderSettingsStore _store;
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();

  OpenAIWireApi _wireApi = OpenAIWireApi.auto;
  List<String> _models = const <String>[];
  bool _loading = true;
  bool _saving = false;
  bool _discoveringModels = false;
  bool _testingConnection = false;
  bool _hasStoredApiKey = false;
  bool _hasStoredConfig = false;
  String? _error;
  String? _probeSuccess;
  AIModelProvider? _probeProvider;
  OpenAIToolCallingModel? _probeToolModel;

  @override
  void initState() {
    super.initState();
    _store = widget.settingsStore ??
        AIProviderSettingsStore(appUserId: widget.appUserId);
    _load();
  }

  Future<void> _load() async {
    AIModelProviderConfig? config;
    String? loadError;
    try {
      config = await _store.readConfig();
    } on AIModelProviderException catch (error) {
      loadError = error.message;
    } catch (_) {
      loadError = '读取模型设置失败';
    }
    bool hasApiKey = false;
    try {
      hasApiKey = await _store.hasApiKey();
    } catch (_) {
      loadError ??= '读取模型设置失败';
    } finally {
      if (mounted) {
        setState(() {
          _endpointController.text = config?.endpoint ?? '';
          _modelController.text = config?.model ?? '';
          _wireApi = config?.wireApi ?? OpenAIWireApi.auto;
          _hasStoredApiKey = hasApiKey;
          _hasStoredConfig = config != null;
          _error = loadError;
          _loading = false;
        });
      }
    }
  }

  bool get _requestBusy => _discoveringModels || _testingConnection;

  Future<String> _resolveApiKey() async {
    final inputApiKey = _apiKeyController.text;
    return inputApiKey.isEmpty && _hasStoredApiKey
        ? (await _store.readApiKey() ?? '')
        : inputApiKey;
  }

  AIModelProviderConfig _currentConfig({String? model}) {
    return AIModelProviderConfig(
      kind: AIModelProviderKind.openAICompatible,
      endpoint: _endpointController.text,
      model: model ?? _modelController.text,
      wireApi: _wireApi,
    );
  }

  /// 只读取服务端模型列表；选择模型不会隐式触发联通或 Tool Calling 测试。
  Future<void> _discoverModels() async {
    AIModelProvider? provider;
    setState(() {
      _discoveringModels = true;
      _error = null;
      _probeSuccess = null;
    });
    try {
      final apiKey = await _resolveApiKey();
      if (!mounted) return;
      final config = _currentConfig();
      final capabilities = widget.modelDiscovery != null
          ? await widget.modelDiscovery!(config, apiKey)
          : await () async {
              provider = OpenAICompatibleProvider(
                config: config,
                apiKey: apiKey,
                dio: OpenAICompatibleProvider.createDio(),
              );
              _probeProvider = provider;
              return provider!.discoverCapabilities();
            }();
      if (!mounted) return;
      setState(() {
        _models = capabilities.models;
        _discoveringModels = false;
        _probeSuccess = _models.isEmpty ? null : '已发现 ${_models.length} 个可用模型';
        if (_models.isEmpty) _error = '服务已连接，但没有返回可用模型';
      });
      if (_models.length == 1) {
        _modelController.text = _models.single;
      } else if (_models.length > 1) {
        await _selectModel(_models);
      }
    } on AIModelProviderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法查询模型列表');
    } finally {
      if (identical(_probeProvider, provider)) _probeProvider = null;
      if (mounted && _discoveringModels) {
        setState(() => _discoveringModels = false);
      }
    }
  }

  /// 只验证当前表单中的模型和 Tool Calling 能力，不查询或改写模型列表。
  Future<void> _testConnection() async {
    setState(() {
      _testingConnection = true;
      _error = null;
      _probeSuccess = null;
    });
    try {
      final selectedModel = _modelController.text.trim();
      if (selectedModel.isEmpty) {
        throw const AIModelProviderConfigurationException(
          '请先查询并选择模型，或手动填写模型名称',
        );
      }
      final apiKey = await _resolveApiKey();
      if (!mounted) return;
      final config = _currentConfig(model: selectedModel);
      if (widget.toolCallingProbe != null) {
        await widget.toolCallingProbe!(config, apiKey);
      } else {
        final toolModel = OpenAIToolCallingModel.fromConfig(
          config: config,
          apiKey: apiKey,
          dio: OpenAICompatibleProvider.createDio(),
        );
        _probeToolModel = toolModel;
        await toolModel.probeToolCalling();
      }
      if (mounted) {
        setState(() => _probeSuccess = '连接成功，Tool Calling 验证通过');
      }
    } on AIModelProviderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法验证模型连接');
    } finally {
      _probeToolModel = null;
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  Future<void> _selectModel(List<String> models) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (context) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final selectedModel = _modelController.text.trim();
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.68,
          ),
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          decoration: BoxDecoration(
            color: isDark ? CampusTheme.darkCard : CampusTheme.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Text(
                '选择模型',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '共发现 ${models.length} 个模型，选择后可单独测试连接。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CampusTheme.subText,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: models.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final model = models[index];
                    final selected = model == selectedModel;
                    return Material(
                      color: selected
                          ? CampusTheme.primary.withValues(alpha: 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => Navigator.of(context).pop(model),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 13,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.smart_toy_outlined,
                                size: 20,
                                color: selected
                                    ? CampusTheme.primary
                                    : CampusTheme.subText,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  model,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (selected)
                                const Icon(
                                  Icons.check_circle_rounded,
                                  size: 21,
                                  color: CampusTheme.primary,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (selected != null && mounted) _modelController.text = selected;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _probeSuccess = null;
    });
    try {
      if (kIsWeb) {
        throw const AIModelProviderException(
          '为保护 API Key，请在 App 客户端配置第三方模型服务',
        );
      }
      AIEndpointPolicy.parseBaseEndpoint(_endpointController.text);
      if (_modelController.text.trim().isEmpty) {
        throw const AIModelProviderException('请先选择或填写模型名称');
      }
      await _store.saveOpenAICompatible(
        endpoint: _endpointController.text,
        model: _modelController.text,
        wireApi: _wireApi,
        apiKey: _apiKeyController.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AIModelProviderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '保存模型设置失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteConfiguration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除模型配置？'),
        content: const Text('会同时删除该配置的 API Key。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.clear();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = '删除模型设置失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearResidualApiKey() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.clearApiKey();
      if (mounted) setState(() => _hasStoredApiKey = false);
    } catch (_) {
      if (mounted) setState(() => _error = '清除残留密钥失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    final probeProvider = _probeProvider;
    _probeProvider = null;
    if (probeProvider != null) {
      unawaited(probeProvider.cancelActiveRequest());
    }
    unawaited(_probeToolModel?.cancel());
    _endpointController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CampusTheme.pageBackground(context),
      appBar: AppPageAppBar(
        title: const Text('模型设置'),
        actions: [
          if (_hasStoredConfig)
            IconButton(
              tooltip: '删除模型配置',
              onPressed: _saving ? null : _deleteConfiguration,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
              children: [
                Text(
                  '个人助手模型',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '个人 Skill 仅使用这里配置的第三方模型；校园公益 AI 不能接收个人数据，也不能执行个人 Skill。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                if (!_hasStoredConfig && _hasStoredApiKey) ...[
                  Text(
                    '检测到残留密钥，请清除后再保存新的模型配置。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _clearResidualApiKey,
                    icon: const Icon(Icons.key_off_rounded),
                    label: const Text('清除残留密钥'),
                  ),
                  const SizedBox(height: 18),
                ],
                TextField(
                  controller: _endpointController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS 服务地址',
                    hintText: 'https://api.example.com/v1',
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _apiKeyController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: _hasStoredApiKey ? '已安全保存，留空则保持不变' : null,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _modelController,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '模型名称'),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<OpenAIWireApi>(
                  key: ValueKey(_wireApi),
                  initialValue: _wireApi,
                  decoration: const InputDecoration(labelText: '请求协议'),
                  items: OpenAIWireApi.values
                      .map(
                        (wireApi) => DropdownMenuItem(
                          value: wireApi,
                          child: Text(wireApi.displayName),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _saving || _requestBusy
                      ? null
                      : (wireApi) {
                          if (wireApi == null) return;
                          setState(() {
                            _wireApi = wireApi;
                            _error = null;
                            _probeSuccess = null;
                          });
                        },
                ),
                const SizedBox(height: 8),
                Text(
                  switch (_wireApi) {
                    OpenAIWireApi.auto =>
                      '自动识别 Claude、DeepSeek 等官方地址；其他服务依次尝试 Responses、Chat Completions 和 Anthropic Messages。',
                    OpenAIWireApi.responses =>
                      '适用于配置中 wire_api = responses 的服务。',
                    OpenAIWireApi.chatCompletions =>
                      '适用于 DeepSeek 等 OpenAI Chat Completions 兼容服务。',
                    OpenAIWireApi.anthropicMessages =>
                      '适用于 Claude 官方 API 和 Anthropic Messages 兼容服务。',
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _requestBusy || _saving ? null : _discoverModels,
                        icon: _discoveringModels
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.manage_search_rounded),
                        label: const Text('查询模型'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _requestBusy || _saving ? null : _testConnection,
                        icon: _testingConnection
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.cable_rounded),
                        label: const Text('测试连接'),
                      ),
                    ),
                  ],
                ),
                if (_models.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '已发现 ${_models.length} 个模型',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                if (_probeSuccess != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _probeSuccess!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('保存模型设置'),
                ),
              ],
            ),
    );
  }
}
