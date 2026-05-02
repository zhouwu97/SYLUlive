import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../main.dart' show getSharedDio;
import '../models/exam_question.dart';
import '../providers/auth_provider.dart';
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('脚本已复制')));
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
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ExamPreviewScreen(questions: questions)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin == true;

    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('题库提取')), body: const Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A2E) : Colors.grey[50],
      appBar: AppBar(
        title: Text(_tutorialTitle ?? '题库提取'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '编辑',
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const _TutorialEditor()));
                _loadTutorial();
              },
            ),
        ],
      ),
      body: _tutorialContent != null
          ? Column(children: [
              Expanded(
                child: Markdown(
                  data: _tutorialContent!,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    h1: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87),
                    h2: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87),
                    p: TextStyle(fontSize: 15, height: 1.7, color: isDark ? Colors.white70 : Colors.grey[800]),
                  ),
                ),
              ),
              SafeArea(child: _bottomBar()),
            ])
          : SingleChildScrollView(padding: const EdgeInsets.all(16), child: _defaultTutorial(isDark)),
    );
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [Expanded(child: _btn('复制脚本', Icons.copy, _copyScript))]),
        const SizedBox(height: 8),
        Row(children: [Expanded(child: _btn('选择 JSON 文件', Icons.folder_open, _importJson))]),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) => ElevatedButton.icon(
      onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label),
      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF667EEA), foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));

  Widget _defaultTutorial(bool d) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('题库提取教程', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: d ? Colors.white : Colors.black87)),
      const SizedBox(height: 20),
      _step('1', '安装油猴插件', d, '电脑 Edge/Chrome/Firefox 浏览器安装 Tampermonkey 扩展'),
      _step('2', '导入脚本', d, '复制脚本 → 油猴管理面板 → 新建 → 粘贴 → 保存'),
      _step('3', '提取题目', d, '浏览器打开 cctrcloud.net → 登录 → 选科目 → 点提取'),
      _step('4', '导入 App', d, 'json 文件传到手机 → 点下面按钮导入'),
      const SizedBox(height: 16),
      _btn('复制脚本', Icons.copy, _copyScript),
      const SizedBox(height: 8),
      _btn('选择 JSON 文件', Icons.folder_open, _importJson),
      const SizedBox(height: 40),
    ]);
  }

  Widget _step(String n, String t, bool d, String b) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 28, height: 28, margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: BoxDecoration(color: d ? Colors.white24 : Colors.grey[300], borderRadius: BorderRadius.circular(8)),
            child: Center(child: Text(n, style: TextStyle(color: d ? Colors.white : Colors.black54, fontWeight: FontWeight.bold)))),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: d ? Colors.white : Colors.black87)),
          const SizedBox(height: 2),
          Text(b, style: TextStyle(fontSize: 14, color: d ? Colors.white60 : Colors.grey[600])),
        ])),
      ]));
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
