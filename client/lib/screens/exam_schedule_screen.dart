import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:add_2_calendar/add_2_calendar.dart';
import '../widgets/glass_container.dart';

// 定义考试模型
class ExamModel {
  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final String location;

  ExamModel({
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.location,
  });

  factory ExamModel.fromJson(Map<String, dynamic> json) {
    return ExamModel(
      name: json['name'],
      startTime: DateTime.parse(json['startTime']),
      endTime: DateTime.parse(json['endTime']),
      location: json['location'],
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'location': location,
      };
}

class ExamScheduleScreen extends StatefulWidget {
  const ExamScheduleScreen({Key? key}) : super(key: key);

  @override
  State<ExamScheduleScreen> createState() => _ExamScheduleScreenState();
}

class _ExamScheduleScreenState extends State<ExamScheduleScreen> {
  List<ExamModel> _exams = [];

  @override
  void initState() {
    super.initState();
    _loadExams();
  }

  Future<void> _loadExams() async {
    final prefs = await SharedPreferences.getInstance();
    final String? examsJson = prefs.getString('local_exams');
    if (examsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(examsJson);
        final now = DateTime.now();

        setState(() {
          _exams = decoded
              .map((e) => ExamModel.fromJson(e))
              // 过滤掉 endTime 早于当前时间的考试
              .where((exam) => exam.endTime.isAfter(now))
              .toList();

          // 按 startTime 升序排序
          _exams.sort((a, b) => a.startTime.compareTo(b.startTime));
        });
      } catch (e) {
        debugPrint('加载考试数据失败: $e');
      }
    }
  }

  Future<void> _saveExams() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_exams.map((e) => e.toJson()).toList());
    await prefs.setString('local_exams', encoded);

    // 保存到 Download 文件夹下的 SYLUlive 子目录
    try {
      Directory? downloadDir;
      if (Platform.isAndroid) {
        downloadDir = Directory('/storage/emulated/0/Download');
      } else {
        downloadDir = await getDownloadsDirectory();
      }

      if (downloadDir != null) {
        final folder = Directory('${downloadDir.path}/SYLUlive');
        if (!await folder.exists()) {
          await folder.create(recursive: true);
        }
        final file = File('${folder.path}/exams.json');
        await file.writeAsString(encoded);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已自动归档至：${file.path}'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('保存至外部目录失败: $e');
    }
  }

  String _formatTime(DateTime time) {
    return '${time.month}月${time.day}日 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String generateExamPrompt() {
    final now = DateTime.now();
    return '''
你是一个专业的教务数据提取助手。请从以下文本中提取考试信息。
当前系统时间为：${now.year}年${now.month}月${now.day}日。
如果文本中只包含月日，请结合当前系统时间推算最合理的年份（例如，当前是12月，考试时间是1月，则年份应为下一年）。

请严格输出 JSON 数组格式，不要包含任何其他解释性文字，字段要求如下：
[
  {
    "name": "科目名称(如：大学物理)",
    "startTime": "YYYY-MM-DD HH:mm",
    "endTime": "YYYY-MM-DD HH:mm",
    "location": "考试地点"
  }
]
''';
  }

  void _showAiImportDialog() {
    final jsonController = TextEditingController();
    bool isAiMode = true;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加考试日程'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('手动添加(暂未开放)')),
                    ButtonSegment(value: true, label: Text('AI 导入')),
                  ],
                  selected: {isAiMode},
                  onSelectionChanged: (Set<bool> newSelection) {
                    setDialogState(() {
                      isAiMode = newSelection.first;
                    });
                  },
                ),
                const SizedBox(height: 20),
                if (isAiMode) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.lightbulb_outline, size: 16, color: Theme.of(context).colorScheme.secondary),
                            const SizedBox(width: 4),
                            Text('使用步骤', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Theme.of(context).colorScheme.secondary)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('1. 点击下方按钮复制提示词；', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        Text('2. 将提示词与考试安排(图/文)发给AI；', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        Text('3. 在下方粘贴 AI 回复的 JSON 代码。', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('一键复制 AI 提示词'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: generateExamPrompt()));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('提示词已复制！请前往 AI 助手处粘贴。')),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: jsonController,
                    maxLines: 8,
                    minLines: 5,
                    decoration: InputDecoration(
                      hintText: '在此粘贴 AI 生成的 JSON 代码...',
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                    ),
                  ),
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('手动添加功能敬请期待', style: TextStyle(color: Colors.grey))),
                  )
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            if (isAiMode)
              FilledButton(
                onPressed: () {
                  _handleAiImport(dialogCtx, jsonController.text);
                },
                child: const Text('解析并导入'),
              ),
          ],
        ),
      ),
    );
  }

  void _handleAiImport(BuildContext dialogCtx, String jsonStr) {
    if (jsonStr.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先粘贴 JSON 内容')));
      return;
    }

    try {
      String cleanJson = jsonStr;
      final RegExp jsonRegex = RegExp(r'```(?:json)?\s*(\[.*?\])\s*```', dotAll: true);
      final match = jsonRegex.firstMatch(jsonStr);

      if (match != null) {
        cleanJson = match.group(1)!;
      } else {
        int start = jsonStr.indexOf('[');
        int end = jsonStr.lastIndexOf(']');
        if (start != -1 && end != -1 && end > start) {
          cleanJson = jsonStr.substring(start, end + 1);
        }
      }

      List<dynamic> parsedList = jsonDecode(cleanJson);
      
      List<ExamModel> newExams = parsedList.map((e) {
        // 如果返回的字段中带有"时:分"但没有指定秒，补全，或者直接由 DateTime.parse 解析
        return ExamModel.fromJson(e);
      }).toList();

      setState(() {
        _exams.addAll(newExams);
        final now = DateTime.now();
        _exams.retainWhere((exam) => exam.endTime.isAfter(now));
        _exams.sort((a, b) => a.startTime.compareTo(b.startTime));
      });

      _saveExams();
      
      if (dialogCtx.mounted) {
        Navigator.pop(dialogCtx);
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功导入 ${newExams.length} 场考试！')),
      );

    } catch (e) {
      debugPrint("AI 导入解析失败: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解析失败，请检查数据格式。\n错误信息: ${e.toString().split('\n').first}')),
      );
    }
  }

  void _addToCalendar(ExamModel exam) {
    final Event event = Event(
      title: '考试: ${exam.name}',
      description: '沈理校园 - 考试提醒',
      location: exam.location,
      startDate: exam.startTime,
      endDate: exam.endTime,
      iosParams: const IOSParams(
        reminder: Duration(hours: 1), // iOS: 提前1小时
      ),
    );
    Add2Calendar.addEvent2Cal(event);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('考试日程'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加考试',
            onPressed: _showAiImportDialog,
          ),
        ],
      ),
      body: _exams.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_note, size: 64, color: isDark ? Colors.white38 : Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text('暂无考试安排', style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600], fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('点击右上角 + 号，使用 AI 快速导入', style: TextStyle(color: isDark ? Colors.white38 : Colors.grey[500], fontSize: 13)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _exams.length,
              itemBuilder: (context, index) {
                final exam = _exams[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: GlassContainer(
                    padding: const EdgeInsets.all(16),
                    borderRadius: 16,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                exam.name,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.access_time, size: 14, color: isDark ? Colors.white54 : Colors.grey[600]),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${_formatTime(exam.startTime)} - ${_formatTime(exam.endTime)}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isDark ? Colors.white70 : Colors.grey[700],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6366F1).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.location_on, color: Color(0xFF6366F1), size: 16),
                              const SizedBox(height: 4),
                              Text(
                                exam.location.isNotEmpty ? exam.location : '未指定',
                                style: const TextStyle(
                                  color: Color(0xFF6366F1),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(Icons.edit_calendar, color: isDark ? Colors.white70 : Colors.grey[600]),
                          tooltip: '添加到系统日历',
                          onPressed: () => _addToCalendar(exam),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
