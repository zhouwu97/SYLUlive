import os
import re

def fix_yuketang():
    file_path = 'e:/AI/xynewui/client/lib/screens/yuketang_class_screen.dart'
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Define the new fetch function to inject
    fetch_func = """
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
"""

    # Inject the function right after applyProviderDefaults
    if 'bool isFetchingModels = false;' not in content:
        content = content.replace('void applyProviderDefaults(String provider) {', fetch_func + '\n    void applyProviderDefaults(String provider) {')

    # Fix auto-detect provider upon load
    detect_logic = """
    if (currentProvider == 'custom') {
      final url = currentUrl?.toLowerCase() ?? '';
      if (url.contains('deepseek')) currentProvider = 'deepseek';
      else if (url.contains('moonshot')) currentProvider = 'kimi';
      else if (url.contains('bigmodel.cn')) currentProvider = 'zhipu';
      else if (url.contains('dashscope')) currentProvider = 'qwen';
      else if (url.contains('openai.com')) currentProvider = 'openai';
    }
"""
    if 'url.contains(\'deepseek\')' not in content:
        content = content.replace('keyCtrl.text = currentKey ?? \'\';', detect_logic + '\n    keyCtrl.text = currentKey ?? \'\';')

    # Remove the `if (isCustomByok) ...[` condition and show the text fields always when `isByok`
    # Also add the fetch icon button next to the model text field
    old_fields_str = """                    if (isCustomByok) ...[
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
                      TextField(
                        controller: modelCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Model Name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ]"""
    
    new_fields_str = """
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
"""
    content = content.replace(old_fields_str, new_fields_str)

    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)

def fix_super_admin():
    file_path = 'e:/AI/xynewui/client/lib/screens/super_admin_screen.dart'
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    fetch_func = """
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
"""

    if 'bool isFetchingModels = false;' not in content:
        content = content.replace('void applyProviderDefaults(String provider) {', fetch_func + '\n    void applyProviderDefaults(String provider) {')

    detect_logic = """
      final url = urlCtrl.text.toLowerCase();
      if (url.contains('deepseek')) currentProvider = 'deepseek';
      else if (url.contains('moonshot')) currentProvider = 'kimi';
      else if (url.contains('bigmodel.cn')) currentProvider = 'zhipu';
      else if (url.contains('dashscope')) currentProvider = 'qwen';
      else if (url.contains('openai.com')) currentProvider = 'openai';
"""
    if 'url.contains(\'deepseek\')' not in content:
        content = content.replace('modelCtrl.text = res.data[\'model_name\'] ?? \'\';', 'modelCtrl.text = res.data[\'model_name\'] ?? \'\';\n' + detect_logic)

    old_fields_str = """                  if (isCustom) ...[
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
                    TextField(
                      controller: modelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Model Name',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ]"""
    
    new_fields_str = """
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
"""
    content = content.replace(old_fields_str, new_fields_str)

    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)

fix_yuketang()
fix_super_admin()
print("Done")
