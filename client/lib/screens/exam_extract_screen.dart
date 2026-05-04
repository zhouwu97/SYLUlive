import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
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
  bool _copyingProject = false;

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
      const SnackBar(content: Text('脚本已复制，去电脑浏览器粘贴到Tampermonkey'), backgroundColor: Colors.green),
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

  /// 将内置的 yongzhiyunkao 项目文件复制到手机存储
  Future<void> _copyProjectToStorage() async {
    setState(() => _copyingProject = true);
    try {
      final manifest = await rootBundle.loadString('AssetManifest.json');
      final manifestJson = json.decode(manifest) as Map<String, dynamic>;
      final projectFiles = manifestJson.keys.where((k) => k.startsWith('assets/yongzhiyunkao/')).toList();

      final dir = Directory('/storage/emulated/0/Download/yongzhiyunkao');
      if (!await dir.exists()) await dir.create(recursive: true);

      for (final assetPath in projectFiles) {
        final relativePath = assetPath.replaceFirst('assets/yongzhiyunkao/', '');
        if (relativePath.isEmpty) continue;
        final targetFile = File('${dir.path}/$relativePath');
        final parentDir = targetFile.parent;
        if (!await parentDir.exists()) await parentDir.create(recursive: true);
        final data = await rootBundle.load(assetPath);
        await targetFile.writeAsBytes(data.buffer.asUint8List());
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('项目已复制到 ${dir.path}，用USB传到电脑即可'), backgroundColor: Colors.green, duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('复制失败: $e'), backgroundColor: Colors.red),
      );
    }
    setState(() => _copyingProject = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin == true;

    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('题库提取'), backgroundColor: Colors.transparent),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
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
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _tutorialContent != null
                  ? Text(_tutorialContent!, style: TextStyle(fontSize: 15, height: 1.7, color: isDark ? Colors.white70 : Colors.grey[800]))
                  : _defaultTutorial(isDark),
            ),
          ),
          _bottomBar(isDark),
        ]),
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
        Expanded(
          child: _copyingProject
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _btn('将文件传到电脑', Icons.phone_android, _copyProjectToStorage),
        ),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) => ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF667EEA),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));

  Widget _defaultTutorial(bool isDark) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
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
          Text('脚本提取 + Markdown 转换', style: TextStyle(fontSize: 14, color: isDark ? Colors.white54 : Colors.grey[600])),
        ]),
      ),
      const SizedBox(height: 32),
      // 第一步
      _sectionCard(isDark, '1', '安装 Tampermonkey', Icons.extension, [
        _stepLine('在电脑浏览器（Chrome / Edge / Firefox）安装 Tampermonkey 扩展'),
        _linkTile('Chrome 商店', 'https://chrome.google.com/webstore/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo', isDark),
        _linkTile('Edge 商店', 'https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd', isDark),
      ]),
      const SizedBox(height: 14),
      // 第二步
      _sectionCard(isDark, '2', '导入油猴脚本', Icons.code, [
        _stepLine('点击下方"复制脚本"按钮'),
        _stepLine('在电脑打开 Tampermonkey → 新建脚本'),
        _stepLine('粘贴全部内容 → 保存（Ctrl+S）'),
        _actionBtn('复制脚本', Icons.copy, _copyScript),
      ]),
      const SizedBox(height: 14),
      // 第三步
      _sectionCard(isDark, '3', '提取题目', Icons.download, [
        _stepLine('电脑浏览器打开练习页面，登录并选择科目'),
        _stepLine('点击右下角"提取题目" → 开始提取'),
        _stepLine('浏览器自动下载 JSON 文件'),
      ]),
      const SizedBox(height: 14),
      // 第四步
      _sectionCard(isDark, '4', '转为 Markdown', Icons.transform, [
        _stepLine('点击下方"将文件传到电脑"按钮'),
        _stepLine('用 USB 连接手机，将 Download/yongzhiyunkao 文件夹复制到电脑'),
        _stepLine('双击打开 convert_to_markdown.html'),
        _stepLine('拖拽 JSON 文件到页面 → 设置选项 → 转换 → 下载 .md'),
        _actionBtn('将文件传到电脑', Icons.phone_android, _copyProjectToStorage),
      ]),
      const SizedBox(height: 14),
      // 第五步
      _sectionCard(isDark, '5', '导入题库', Icons.folder_open, [
        _stepLine('将转换后的 .json 文件发送到手机（QQ/微信）'),
        _stepLine('在 App 内点击下方按钮，选择文件导入'),
        _actionBtn('导入 JSON 文件', Icons.folder_open, _importJson),
      ]),
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
            decoration: BoxDecoration(color: const Color(0xFF667EEA).withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
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
          icon: Icon(icon, size: 16),
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
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: () async {
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
        },
        child: Row(children: [
          Icon(Icons.open_in_new, size: 14, color: Colors.blue[300]),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, color: Colors.blue[300], decoration: TextDecoration.underline)),
        ]),
      ),
    );
  }
}

// 教程编辑器（管理员用）
class _TutorialEditor extends StatefulWidget {
  const _TutorialEditor();
  @override
  State<_TutorialEditor> createState() => _TutorialEditorState();
}

class _TutorialEditorState extends State<_TutorialEditor> {
  late TextEditingController _ctrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    try {
      final dio = getSharedDio();
      final resp = await dio.get('/tutorial/exam_extract');
      if (resp.statusCode == 200) _ctrl.text = resp.data['content'] ?? '';
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final dio = getSharedDio();
      await dio.put('/tutorial/exam_extract', data: {'title': '题库提取教程', 'content': _ctrl.text});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存成功'), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red));
    }
    setState(() => _saving = false);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('编辑题库提取教程'),
        backgroundColor: Colors.transparent,
        actions: [IconButton(icon: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save), onPressed: _saving ? null : _save)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _ctrl,
          maxLines: null,
          expands: true,
          style: TextStyle(fontSize: 14, color: isDark ? Colors.white70 : Colors.grey[800]),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '输入教程内容...'),
        ),
      ),
    );
  }
}
