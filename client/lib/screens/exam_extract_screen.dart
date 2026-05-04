import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart' show getSharedDio;
import '../models/exam_question.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import 'exam_preview_screen.dart';

class ExamExtractScreen extends StatefulWidget {
  const ExamExtractScreen({super.key});
  @override
  State<ExamExtractScreen> createState() => _ExamExtractScreenState();
}

class _ExamExtractScreenState extends State<ExamExtractScreen> {
  String _scriptContent = '';
  String? _tutorialTitle;
  String? _tutorialContent;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadScript();
    _loadTutorial();
  }

  Future<void> _loadScript() async {
    try {
      _scriptContent = await rootBundle.loadString('assets/scripts/tampermonkey_script.js');
      setState(() {});
    } catch (_) {}
  }

  Future<void> _loadTutorial() async {
    try {
      final dio = getSharedDio();
      final resp = await dio.get('/tutorial/exam_extract');
      if (resp.statusCode == 200) {
        setState(() {
          _tutorialTitle = resp.data['title'];
          _tutorialContent = resp.data['content'];
          _loading = false;
        });
        return;
      }
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _copyScript() async {
    await Clipboard.setData(ClipboardData(text: _scriptContent));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('脚本已复制到剪贴板'), backgroundColor: Colors.green),
    );
  }

  Future<void> _importJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      if (result == null || result.files.isEmpty) return;
      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final list = json.decode(content) as List<dynamic>;
      final questions = list.map((e) => ExamQuestion.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ExamPreviewScreen(questions: questions)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _openGitHub() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.open_in_browser, color: Colors.blue),
          SizedBox(width: 8),
          Text('打开 GitHub'),
        ]),
        content: const Text('将使用浏览器打开项目源码页面，是否继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('打开')),
        ],
      ),
    );
    if (confirmed == true) {
      final uri = Uri.parse('https://github.com/luokehan/yongzhiyunkao');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin == true;
    final themeProvider = context.watch<ThemeProvider>();

    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('题库提取'), backgroundColor: Colors.transparent),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_tutorialTitle ?? '题库提取'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '编辑教程',
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const _TutorialEditor()));
                _loadTutorial();
              },
            ),
          IconButton(
            icon: const Icon(Icons.code),
            tooltip: 'GitHub',
            onPressed: _openGitHub,
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBackground(themeProvider, isDark),
          _tutorialContent != null
              ? SafeArea(
                  child: Column(children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Text(_tutorialContent!,
                            style: TextStyle(fontSize: 15, height: 1.7, color: isDark ? Colors.white70 : Colors.grey[800])),
                      ),
                    ),
                    _bottomBar(isDark),
                  ]),
                )
              : SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _defaultTutorial(isDark),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath', fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildGradient(isDark))
            : bgPath.startsWith('/')
                ? File(bgPath).existsSync()
                    ? Image.file(File(bgPath), fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _buildGradient(isDark))
                    : _buildGradient(isDark)
                : Image.network(bgPath, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildGradient(isDark)),
        Container(color: isDark ? Colors.black.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.3)),
      ]);
    }
    return _buildGradient(isDark);
  }

  Widget _buildGradient(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E), const Color(0xFF0F3460)]
              : [const Color(0xFF667EEA), const Color(0xFF764BA2), const Color(0xFFF093FB)],
        ),
      ),
    );
  }

  Widget _bottomBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.black.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.3),
      ),
      child: Row(children: [
        Expanded(child: _btn('复制脚本', Icons.copy, _copyScript)),
        const SizedBox(width: 12),
        Expanded(child: _btn('导入 JSON', Icons.folder_open, _importJson)),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) => ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF667EEA),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));

  Widget _defaultTutorial(bool isDark) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      // 标题
      Center(
        child: Column(children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF667EEA), Color(0xFF764BA2)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.auto_stories, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 16),
          Text('融智云考 · 题库提取', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 8),
          Text('练习题提取 + Markdown 转换', style: TextStyle(fontSize: 14, color: isDark ? Colors.white54 : Colors.grey[600])),
        ]),
      ),

      const SizedBox(height: 32),

      // 第一步：安装油猴
      _sectionCard(isDark, '1', '安装 Tampermonkey', Icons.extension, [
        _stepLine('电脑浏览器（Chrome / Edge / Firefox）安装 Tampermonkey 扩展'),
        _linkTile('Chrome 商店', 'https://chrome.google.com/webstore/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo', isDark),
        _linkTile('Edge 商店', 'https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd', isDark),
        _linkTile('Firefox 商店', 'https://addons.mozilla.org/firefox/addon/tampermonkey/', isDark),
      ]),

      const SizedBox(height: 14),

      // 第二步：导入脚本
      _sectionCard(isDark, '2', '导入脚本', Icons.code, [
        _stepLine('点击下方"复制脚本"按钮'),
        _stepLine('打开 Tampermonkey 管理面板 → 新建脚本'),
        _stepLine('粘贴全部内容 → 保存（Ctrl+S）'),
        _actionBtn('复制脚本', Icons.copy, _copyScript),
      ]),

      const SizedBox(height: 14),

      // 第三步：提取题目
      _sectionCard(isDark, '3', '提取题目', Icons.download, [
        _stepLine('浏览器打开练习页面（如 kwk.ahau.edu.cn）'),
        _stepLine('登录 → 选择科目 → 点击右下角"提取题目"'),
        _stepLine('在弹出面板点击"开始提取"，等待完成'),
        _stepLine('浏览器自动下载 JSON 文件'),
      ]),

      const SizedBox(height: 14),

      // 第四步：转换导入
      _sectionCard(isDark, '4', '转换 & 导入', Icons.swap_horiz, [
        _stepLine('JSON 文件从电脑发送到手机（QQ/微信文件传输）'),
        _stepLine('在手机打开此 App，点击下方"导入 JSON"'),
        _stepLine('选择 json 文件 → 自动预览题目'),
        _actionBtn('导入 JSON 文件', Icons.folder_open, _importJson),
      ]),

      const SizedBox(height: 14),

      // 转换工具
      _sectionCard(isDark, '🔧', '格式转换工具', Icons.transform, [
        _stepLine('打开 convert_to_markdown.html（双击或拖入浏览器）'),
        _stepLine('拖拽 JSON 文件到上传区域'),
        _stepLine('设置选项（目录/统计/答案标记/章节分组）'),
        _stepLine('点击转换 → 下载 .md 文件'),
      ]),

      const SizedBox(height: 24),

      // GitHub 链接
      Center(
        child: TextButton.icon(
          onPressed: _openGitHub,
          icon: const Icon(Icons.code, size: 18),
          label: const Text('GitHub 源码'),
          style: TextButton.styleFrom(foregroundColor: isDark ? Colors.white54 : Colors.grey[600]),
        ),
      ),

      const SizedBox(height: 40),
    ]);
  }

  Widget _sectionCard(bool isDark, String num, String title, IconData icon, List<Widget> children) {
    return GlassContainer(
      padding: const EdgeInsets.all(18),
      borderRadius: 16,
      blur: 8,
      opacity: isDark ? 0.12 : 0.3,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF667EEA).withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(child: Text(num, style: const TextStyle(color: Color(0xFF667EEA), fontWeight: FontWeight.bold, fontSize: 13))),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 18, color: const Color(0xFF667EEA)),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87)),
        ]),
        const SizedBox(height: 14),
        ...children,
      ]),
    );
  }

  Widget _stepLine(String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('• $text', style: TextStyle(fontSize: 14, height: 1.5, color: isDark ? Colors.white70 : Colors.grey[700])),
    );
  }

  Widget _actionBtn(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF667EEA),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }

  Widget _linkTile(String label, String url, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () async {
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.open_in_new, size: 14, color: const Color(0xFF667EEA)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, color: isDark ? Colors.white54 : Colors.grey[600], decoration: TextDecoration.underline)),
        ]),
      ),
    );
  }
}

/// 管理员编辑教程
class _TutorialEditor extends StatefulWidget {
  const _TutorialEditor();
  @override
  State<_TutorialEditor> createState() => _TutorialEditorState();
}

class _TutorialEditorState extends State<_TutorialEditor> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resp = await getSharedDio().get('/tutorial/exam_extract');
      _title.text = resp.data['title'] ?? '';
      _content.text = resp.data['content'] ?? '';
      setState(() {});
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await getSharedDio().put('/tutorial/exam_extract', data: {'title': _title.text, 'content': _content.text});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存成功'), backgroundColor: Colors.green));
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑教程'),
        actions: [
          IconButton(
            icon: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _title, decoration: const InputDecoration(labelText: '标题', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          Expanded(
            child: TextField(controller: _content, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(labelText: '内容（Markdown）', border: OutlineInputBorder(), alignLabelWithHint: true)),
          ),
        ]),
      ),
    );
  }
}
