import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/ai_runtime/ai_endpoint_policy.dart';
import '../../features/ai_runtime/ai_model_provider.dart';
import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../features/ai_runtime/campus_public_provider.dart';
import '../../features/ai_runtime/openai_compatible_provider.dart';
import '../../main.dart';
import '../../services/ai_assistant_service.dart';

class AIModelSettingsScreen extends StatefulWidget {
  const AIModelSettingsScreen({
    super.key,
    required this.appUserId,
  });

  final String appUserId;

  @override
  State<AIModelSettingsScreen> createState() => _AIModelSettingsScreenState();
}

class _AIModelSettingsScreenState extends State<AIModelSettingsScreen> {
  late final AIProviderSettingsStore _store;
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();

  AIModelProviderKind _kind = AIModelProviderKind.campusPublic;
  List<String> _models = const <String>[];
  bool _loading = true;
  bool _saving = false;
  bool _probing = false;
  bool _hasStoredApiKey = false;
  bool _hasStoredConfig = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _store = AIProviderSettingsStore(appUserId: widget.appUserId);
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await _store.readConfig();
      final hasApiKey = await _store.hasApiKey();
      if (!mounted) return;
      setState(() {
        _kind = config?.kind ?? AIModelProviderKind.campusPublic;
        _endpointController.text = config?.endpoint ?? '';
        _modelController.text = config?.model ?? '';
        _hasStoredApiKey = hasApiKey;
        _hasStoredConfig = config != null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '读取模型设置失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _probeModels() async {
    setState(() {
      _probing = true;
      _error = null;
    });
    try {
      final provider = _kind == AIModelProviderKind.campusPublic
          ? CampusPublicProvider(AiAssistantService(getSharedDio()))
          : OpenAICompatibleProvider(
              config: AIModelProviderConfig(
                kind: _kind,
                endpoint: _endpointController.text,
                model: _modelController.text,
              ),
              apiKey: _apiKeyController.text.isEmpty && _hasStoredApiKey
                  ? (await _store.readApiKey() ?? '')
                  : _apiKeyController.text,
              dio: Dio(),
            );
      final capabilities = await provider.discoverCapabilities();
      if (!mounted) return;
      setState(() {
        _models = capabilities.models;
        if (capabilities.chatAvailability ==
            AIModelChatAvailability.unavailable) {
          _error = '当前服务未开放普通聊天';
        }
      });
      if (_models.length == 1) {
        _modelController.text = _models.single;
      } else if (_models.length > 1) {
        await _selectModel(_models);
      }
    } on AIModelProviderException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法探测模型能力');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _selectModel(List<String> models) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: models.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) => ListTile(
            title: Text(models[index]),
            onTap: () => Navigator.of(context).pop(models[index]),
          ),
        ),
      ),
    );
    if (selected != null && mounted) _modelController.text = selected;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_kind == AIModelProviderKind.campusPublic) {
        await _store.saveCampusPublic();
      } else {
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
          apiKey: _apiKeyController.text,
        );
      }
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

  @override
  void dispose() {
    _endpointController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
                DropdownButtonFormField<AIModelProviderKind>(
                  key: ValueKey(_kind),
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: '模型服务'),
                  items: AIModelProviderKind.values
                      .map(
                        (kind) => DropdownMenuItem(
                          value: kind,
                          child: Text(kind.displayName),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (kind) {
                          if (kind == null) return;
                          setState(() {
                            _kind = kind;
                            _models = const <String>[];
                            _error = null;
                          });
                        },
                ),
                if (_kind == AIModelProviderKind.openAICompatible) ...[
                  const SizedBox(height: 18),
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
                ],
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _probing || _saving ? null : _probeModels,
                  icon: _probing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore_rounded),
                  label: const Text('探测能力'),
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
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ],
            ),
    );
  }
}
