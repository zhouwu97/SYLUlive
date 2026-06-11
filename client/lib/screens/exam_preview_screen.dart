import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../models/exam_question.dart';

/// 题库预览 & Markdown 转换页面
class ExamPreviewScreen extends StatefulWidget {
  final List<ExamQuestion> questions;

  const ExamPreviewScreen({super.key, required this.questions});

  @override
  State<ExamPreviewScreen> createState() => _ExamPreviewScreenState();
}

class _ExamPreviewScreenState extends State<ExamPreviewScreen> {
  final _converter = ExamMarkdownConverter();
  String _markdown = '';
  bool _loaded = false;

  bool _includeToc = true;
  bool _includeStats = true;
  bool _markCorrect = true;
  bool _groupByChapter = true;

  @override
  void initState() {
    super.initState();
    _convert();
  }

  void _convert() {
    final converter = ExamMarkdownConverter(
      includeToc: _includeToc,
      includeStats: _includeStats,
      markCorrectAnswers: _markCorrect,
      groupByChapter: _groupByChapter,
    );
    if (mounted) setState(() {
      _markdown = converter.convert(widget.questions);
      _loaded = true;
    });
  }

  Future<void> _saveToFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/练习题_$timestamp.md');
      await file.writeAsString(_markdown);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存到: ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final questions = widget.questions;

    // 统计
    final typeCount = <String, int>{};
    double totalScore = 0;
    final chapters = <String>{};
    for (final q in questions) {
      final type = q.questionType.isNotEmpty ? q.questionType : '未知';
      typeCount[type] = (typeCount[type] ?? 0) + 1;
      totalScore += double.tryParse(q.score ?? '0') ?? 0;
      if (q.chapter != null && q.chapter!.isNotEmpty) chapters.add(q.chapter!);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('题库预览'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.save_alt), onPressed: _saveToFile, tooltip: '保存为文件'),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _markdown));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')),
              );
            },
            tooltip: '复制全文',
          ),
        ],
      ),
      body: _loaded
          ? Column(
              children: [
                // 统计卡片
                Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _statItem('总题数', '${questions.length}'),
                      _statItem('总分值', '$totalScore'),
                      _statItem('章节数', '${chapters.length}'),
                    ],
                  ),
                ),
                // 选项
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      _optionChip('目录', _includeToc, (v) {
                        setState(() { _includeToc = v; _convert(); });
                      }),
                      const SizedBox(width: 4),
                      _optionChip('统计', _includeStats, (v) {
                        setState(() { _includeStats = v; _convert(); });
                      }),
                      const SizedBox(width: 4),
                      _optionChip('标答案', _markCorrect, (v) {
                        setState(() { _markCorrect = v; _convert(); });
                      }),
                      const SizedBox(width: 4),
                      _optionChip('按章节', _groupByChapter, (v) {
                        setState(() { _groupByChapter = v; _convert(); });
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Markdown 预览
                Expanded(
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _markdown,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.6,
                          color: Theme.of(context).textTheme.bodyMedium?.color,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _statItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }

  Widget _optionChip(String label, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: value,
      onSelected: onChanged,
      visualDensity: VisualDensity.compact,
      selectedColor: const Color(0xFF667EEA).withValues(alpha: 0.2),
      checkmarkColor: const Color(0xFF667EEA),
    );
  }
}
