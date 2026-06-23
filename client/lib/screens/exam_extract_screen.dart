import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../main.dart' show getSharedDio;
import '../models/exam_question.dart';
import '../providers/auth_provider.dart';
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
      _scriptContent =
          await rootBundle.loadString('assets/scripts/tampermonkey_script.js');
      setState(() {});
    } catch (_) {}
  }

  Future<void> _loadTutorial() async {
    try {
      final dio = getSharedDio();
      final resp = await dio.get('/tutorial/exam_extract');
      if (resp.statusCode == 200) {
        if (mounted)
          setState(() {
            _tutorialTitle = resp.data['title'];
            _tutorialContent = resp.data['content'];
            _loading = false;
          });
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _shareFiles() async {
    if (mounted) setState(() => _copyingProject = true);
    try {
      final tempDir = await getTemporaryDirectory();

      // 提取脚本
      final scriptData =
          await rootBundle.load('assets/scripts/tampermonkey_script.js');
      final scriptFile = File('${tempDir.path}/tampermonkey_script.js');
      await scriptFile.writeAsBytes(scriptData.buffer.asUint8List());

      // 提取HTML
      final htmlData = await rootBundle
          .load('assets/yongzhiyunkao/convert_to_markdown.html');
      final htmlFile = File('${tempDir.path}/convert_to_markdown.html');
      await htmlFile.writeAsBytes(htmlData.buffer.asUint8List());

      // 分享
      if (!mounted) return;
      await Share.shareXFiles([
        XFile(scriptFile.path),
        XFile(htmlFile.path),
      ], text: '融智云考提取工具（包含脚本与HTML转换工具）');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分享失败: $e'), backgroundColor: Colors.red),
      );
    }
    if (mounted) setState(() => _copyingProject = false);
  }

  Future<void> _importJson() async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      if (result == null || result.files.isEmpty) return;
      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final list = json.decode(content) as List<dynamic>;
      final questions = list
          .map((e) => ExamQuestion.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ExamPreviewScreen(questions: questions)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin == true;

    if (_loading) {
      return Scaffold(
        backgroundColor: _pageBackgroundColor(isDark),
        appBar: AppBar(
          title: const Text('题库提取'),
          backgroundColor: Colors.transparent,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: _pageBackgroundColor(isDark),
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
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const _TutorialEditor()));
                _loadTutorial();
              },
            ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [
                    Color(0xFF10131A),
                    Color(0xFF151A24),
                    Color(0xFF1B2230),
                  ]
                : const [
                    Color(0xFFF8FAFF),
                    Color(0xFFF2F5FF),
                    Color(0xFFEAEFFD),
                  ],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _tutorialContent != null
                    ? Text(_tutorialContent!,
                        style: TextStyle(
                            fontSize: 15,
                            height: 1.7,
                            color: isDark ? Colors.white70 : Colors.grey[800]))
                    : _defaultTutorial(isDark),
              ),
            ),
            _bottomBar(isDark),
          ]),
        ),
      ),
    );
  }

  Color _pageBackgroundColor(bool isDark) {
    return isDark ? const Color(0xFF10131A) : const Color(0xFFF8FAFF);
  }

  Widget _bottomBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF111723).withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.86),
      ),
      child: Row(children: [
        Expanded(
          child: _copyingProject
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF667EEA)))
              : _btn('分享提取工具', Icons.share, _shareFiles),
        ),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) =>
      ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, style: const TextStyle(fontSize: 13)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF667EEA),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ));

  Widget _defaultTutorial(bool isDark) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      Center(
        child: Column(children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFF667EEA), Color(0xFF764BA2)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child:
                const Icon(Icons.auto_stories, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 16),
          Text('融智云考 · 题库提取',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 8),
          Text('脚本提取 + Markdown 转换',
              style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : Colors.grey[600])),
        ]),
      ),
      const SizedBox(height: 32),
      // 第一步
      _sectionCard(isDark, '1', '获取工具', Icons.share, [
        _stepLine('点击下方"分享提取工具"按钮，将文件分享到电脑（可通过微信/QQ文件传输助手）'),
        _stepLine(
            '您会在电脑收到两个文件：tampermonkey_script.js 和 convert_to_markdown.html'),
        _actionBtn('分享提取工具', Icons.share, _shareFiles),
      ]),
      const SizedBox(height: 14),
      // 第二步
      _sectionCard(isDark, '2', '安装脚本', Icons.extension, [
        _stepLine('请确保电脑浏览器已安装好 Tampermonkey (油猴) 扩展'),
        _stepLine('打开 Tampermonkey 管理面板'),
        _stepLine('直接将刚刚收到的 tampermonkey_script.js 拖进浏览器中，点击"安装"即可'),
      ]),
      const SizedBox(height: 14),
      // 第三步
      _sectionCard(isDark, '3', '导出题库', Icons.download, [
        _stepLine('在电脑打开融智云考，登录并进入练习页面'),
        _stepLine('此时页面会出现题库提取面板，可以直接使用"提取题目"功能导出 json 文件'),
      ]),
      const SizedBox(height: 14),
      // 第四步
      _sectionCard(isDark, '4', '转为 Markdown', Icons.transform, [
        _stepLine('在电脑双击打开收到的 convert_to_markdown.html 文件'),
        _stepLine('将刚刚从融智云考导出的 json 文件拖进该网页中'),
        _stepLine('网页会自动将其转换为排版精美的 Markdown 格式，然后就可以使用了！'),
      ]),
      const SizedBox(height: 14),
      // 第五步
      _sectionCard(isDark, '5', '在手机端练习', Icons.folder_open, [
        _stepLine('如果您想在手机上练习，可以将导出的 json 文件再传回手机'),
        _stepLine('点击下方按钮，选择文件即可在 App 内导入并直接进行做题练习'),
        _actionBtn('导入 JSON 题库到手机端', Icons.folder_open, _importJson),
      ]),
      const SizedBox(height: 40),
    ]);
  }

  Widget _sectionCard(bool isDark, String num, String title, IconData icon,
      List<Widget> children) {
    return GlassContainer(
      padding: const EdgeInsets.all(18),
      borderRadius: 16,
      blur: 8,
      opacity: isDark ? 0.12 : 0.3,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                color: const Color(0xFF667EEA).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8)),
            child: Center(
                child: Text(num,
                    style: const TextStyle(
                        color: Color(0xFF667EEA),
                        fontWeight: FontWeight.bold,
                        fontSize: 13))),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 18, color: const Color(0xFF667EEA)),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87)),
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
      child: Text('• $text',
          style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: isDark ? Colors.white70 : Colors.grey[700])),
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
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: Row(children: [
          Icon(Icons.open_in_new, size: 14, color: Colors.blue[300]),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.blue[300],
                  decoration: TextDecoration.underline)),
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
    if (mounted) setState(() => _saving = true);
    try {
      final dio = getSharedDio();
      await dio.put('/tutorial/exam_extract',
          data: {'title': '题库提取教程', 'content': _ctrl.text});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('保存成功'), backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF10131A) : const Color(0xFFF8FAFF),
      appBar: AppBar(
        title: const Text('编辑题库提取教程'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              onPressed: _saving ? null : _save)
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _ctrl,
          maxLines: null,
          expands: true,
          style: TextStyle(
              fontSize: 14, color: isDark ? Colors.white70 : Colors.grey[800]),
          decoration: const InputDecoration(
              border: OutlineInputBorder(), hintText: '输入教程内容...'),
        ),
      ),
    );
  }
}
