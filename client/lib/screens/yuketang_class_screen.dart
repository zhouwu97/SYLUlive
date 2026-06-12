import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';
import '../widgets/yuketang_webview_widget.dart';

class YuketangClassScreen extends StatefulWidget {
  const YuketangClassScreen({Key? key}) : super(key: key);

  @override
  State<YuketangClassScreen> createState() => _YuketangClassScreenState();
}

class _YuketangClassScreenState extends State<YuketangClassScreen> {
  final GlobalKey<YuketangWebViewWidgetState> _webViewKey = GlobalKey();
  final _storage = const FlutterSecureStorage();
  final keyCtrl = TextEditingController();
  final urlCtrl = TextEditingController();
  final modelCtrl = TextEditingController();
  String? _lastInterceptedExamData;

  @override
  void dispose() {
    keyCtrl.dispose();
    urlCtrl.dispose();
    modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleBack() async {
    final controller = _webViewKey.currentState?.webViewController;
    if (controller != null && await controller.canGoBack()) {
      controller.goBack();
    } else {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _showSettingsDialog() async {
    keyCtrl.text = '';
    urlCtrl.text = '';
    modelCtrl.text = '';

    final currentKey = await _storage.read(key: 'custom_api_key');
    final currentUrl = await _storage.read(key: 'custom_base_url');
    final currentModel = await _storage.read(key: 'custom_model_name');
    String currentProvider = await _storage.read(key: 'custom_ai_provider') ?? 'default';
    String currentMode = await _storage.read(key: 'auto_submit_mode') ?? 'semi';

    
    if (currentProvider == 'custom') {
      final url = currentUrl?.toLowerCase() ?? '';
      if (url.contains('deepseek')) currentProvider = 'deepseek';
      else if (url.contains('moonshot')) currentProvider = 'kimi';
      else if (url.contains('bigmodel.cn')) currentProvider = 'zhipu';
      else if (url.contains('dashscope')) currentProvider = 'qwen';
      else if (url.contains('openai.com')) currentProvider = 'openai';
    }

    keyCtrl.text = currentKey ?? '';
    urlCtrl.text = currentUrl ?? '';
    modelCtrl.text = currentModel ?? '';

    // 如果选了自带，并且是预设提供商，则锁定URL和模型输入
    
    bool isFetchingModels = false;
    Future<void> fetchModels(StateSetter setDialogState) async {
      if (urlCtrl.text.isEmpty || keyCtrl.text.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先填写 Base URL 和 API Key')));
        return;
      }
      setDialogState(() => isFetchingModels = true);
      try {
        final dio = Dio();
        String url = urlCtrl.text.trim();
        if (!url.endsWith('/models')) {
          url = url.endsWith('/') ? '${url}models' : '$url/models';
        }
        final res = await dio.get(
          url,
          options: Options(headers: {'Authorization': 'Bearer ${keyCtrl.text.trim()}'}),
        );
        if (res.statusCode == 200 && res.data['data'] != null) {
          final List data = res.data['data'];
          final availableModels = data.map((e) => e['id'].toString()).toList();
          if (availableModels.isNotEmpty) {
            if (mounted) {
              showModalBottomSheet(
                context: context,
                builder: (ctx) => ListView.builder(
                  itemCount: availableModels.length,
                  itemBuilder: (ctx, index) => ListTile(
                    title: Text(availableModels[index]),
                    onTap: () {
                      setDialogState(() {
                        modelCtrl.text = availableModels[index];
                      });
                      Navigator.pop(ctx);
                    },
                  ),
                ),
              );
            }
          } else {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未获取到模型列表')));
          }
        } else {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('获取失败')));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请求失败: $e')));
      } finally {
        setDialogState(() => isFetchingModels = false);
      }
    }

    void applyProviderDefaults(String provider) {
      if (provider == 'deepseek') {
        urlCtrl.text = 'https://api.deepseek.com/v1';
        modelCtrl.text = 'deepseek-chat';
      } else if (provider == 'kimi') {
        urlCtrl.text = 'https://api.moonshot.cn/v1';
        modelCtrl.text = 'moonshot-v1-8k';
      } else if (provider == 'zhipu') {
        urlCtrl.text = 'https://open.bigmodel.cn/api/paas/v4';
        modelCtrl.text = 'glm-4-flash';
      } else if (provider == 'qwen') {
        urlCtrl.text = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
        modelCtrl.text = 'qwen-turbo';
      } else if (provider == 'openai') {
        urlCtrl.text = 'https://api.openai.com/v1';
        modelCtrl.text = 'gpt-3.5-turbo';
      } else if (provider == 'custom') {
        // 自定义保持不变
      }
    }

    if (!context.mounted) return;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isByok = currentProvider != 'default';
          final isCustomByok = currentProvider == 'custom';

          return AlertDialog(
            title: const Text('助手核心设置'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('⚙️ 答题模式', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  RadioListTile<String>(
                    title: const Text('半自动 (辅助选填)'),
                    subtitle: const Text('自动选择选项，需手动提交'),
                    value: 'semi',
                    groupValue: currentMode,
                    onChanged: (val) => setDialogState(() => currentMode = val!),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<String>(
                    title: const Text('全自动 (托管摸鱼)'),
                    subtitle: const Text('自动选择并提交，彻底解放双手'),
                    value: 'full',
                    groupValue: currentMode,
                    onChanged: (val) => setDialogState(() => currentMode = val!),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Divider(height: 32),
                  const Text('🤖 AI 接口来源', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  RadioListTile<String>(
                    title: const Text('内置大模型 (消耗积分)'),
                    value: 'default',
                    groupValue: currentProvider == 'default' ? 'default' : 'byok',
                    onChanged: (val) => setDialogState(() {
                      currentProvider = 'default';
                    }),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<String>(
                    title: const Text('自定义模型 (BYOK, 自带)'),
                    value: 'byok',
                    groupValue: currentProvider == 'default' ? 'default' : 'byok',
                    onChanged: (val) => setDialogState(() {
                      currentProvider = 'deepseek';
                      applyProviderDefaults(currentProvider);
                    }),
                    contentPadding: EdgeInsets.zero,
                  ),
                  
                  if (isByok) ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: currentProvider,
                      decoration: const InputDecoration(
                        labelText: '大模型提供商',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                        DropdownMenuItem(value: 'kimi', child: Text('Kimi (月之暗面)')),
                        DropdownMenuItem(value: 'zhipu', child: Text('智谱清言')),
                        DropdownMenuItem(value: 'qwen', child: Text('通义千问')),
                        DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                        DropdownMenuItem(value: 'custom', child: Text('自定义 (Custom)')),
                      ],
                      onChanged: (val) {
                        setDialogState(() {
                          currentProvider = val!;
                          applyProviderDefaults(currentProvider);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: keyCtrl,
                      decoration: const InputDecoration(
                        labelText: 'API Key (必填)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      obscureText: true,
                    ),

                      const SizedBox(height: 12),
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Base URL',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: modelCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Model Name',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          isFetchingModels 
                              ? const CircularProgressIndicator()
                              : IconButton(
                                  icon: const Icon(Icons.sync),
                                  onPressed: () => fetchModels(setDialogState),
                                  tooltip: '获取可用模型',
                                ),
                        ],
                      ),

                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _storage.write(key: 'auto_submit_mode', value: currentMode);
                  await _storage.write(key: 'custom_ai_provider', value: currentProvider);
                  if (currentProvider != 'default') {
                    await _storage.write(key: 'custom_api_key', value: keyCtrl.text.trim());
                    await _storage.write(key: 'custom_base_url', value: urlCtrl.text.trim());
                    await _storage.write(key: 'custom_model_name', value: modelCtrl.text.trim());
                  }
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存')));
                },
                child: const Text('保存'),
              ),
            ],
          );
        }
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          await _handleBack();
        },
        child: Scaffold(
          resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: const Text('长江雨课堂'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSettingsDialog,
              tooltip: '设置与 AI 配置',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _webViewKey.currentState?.webViewController?.reload();
              },
            ),
          ],
        ),
        body: YuketangWebViewWidget(
          key: _webViewKey,
          url: 'https://changjiang.yuketang.cn/v2/web/index',
        ),
      ),
    ));
  }
}
