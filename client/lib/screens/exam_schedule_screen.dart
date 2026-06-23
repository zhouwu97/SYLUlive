import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/edu_provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../widgets/glass_container.dart';

// 定义考试模型
class ExamModel {
  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final String location;
  final String semester;

  ExamModel({
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.location,
    this.semester = '',
  });

  factory ExamModel.fromJson(Map<String, dynamic> json) {
    return ExamModel(
      name: json['name'] ?? '',
      startTime: DateTime.parse(json['startTime']),
      endTime: DateTime.parse(json['endTime']),
      location: json['location'] ?? '',
      semester: json['semester'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'location': location,
    'semester': semester,
  };
}

class ExamScheduleScreen extends StatefulWidget {
  const ExamScheduleScreen({Key? key}) : super(key: key);

  @override
  State<ExamScheduleScreen> createState() => _ExamScheduleScreenState();
}

class _ExamScheduleScreenState extends State<ExamScheduleScreen> {
  List<ExamModel> _exams = [];
  Timer? _syncTimer;

  late String _currentSemester;

  List<String> get _availableSemesters {
    final s = _exams.map((e) => e.semester).where((s) => s.isNotEmpty).toSet();
    final now = DateTime.now();
    int startYear = now.year - 4; // 默认往前推4年

    try {
      startYear = context.read<EduProvider>().enrollmentYear;
    } catch (_) {}

    int count = (now.year - startYear) + 2;
    if (count < 4) count = 4;

    for (int i = 0; i < count; i++) {
      int year = startYear + i;
      s.add('${year}-${year + 1}-01');
      s.add('${year}-${year + 1}-02');
    }

    if (!s.contains(_currentSemester)) {
      s.add(_currentSemester);
    }
    final list = s.toList();
    list.sort((a, b) => b.compareTo(a));
    return list;
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final year = now.year;
    if (now.month >= 8) {
      _currentSemester = '${year}-${year + 1}-01';
    } else if (now.month <= 2) {
      _currentSemester = '${year - 1}-${year}-01';
    } else {
      _currentSemester = '${year - 1}-${year}-02';
    }
    _loadExams();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadExams() async {
    final prefs = await SharedPreferences.getInstance();
    final String? examsJson = prefs.getString('local_exams');
    if (examsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(examsJson);

        if (mounted)
          setState(() {
            _exams = decoded.map((e) => ExamModel.fromJson(e)).toList();

            // 按 startTime 升序排序
            _exams.sort((a, b) => a.startTime.compareTo(b.startTime));
          });
      } catch (e) {
        debugPrint('加载考试数据失败: $e');
      }

      _syncWidget();
    }
  }

  Future<void> _saveToLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_exams.map((e) => e.toJson()).toList());
    await prefs.setString('local_exams', encoded);
    _syncWidget();
  }

  Future<void> _exportExams() async {
    if (_exams.where((e) => e.semester == _currentSemester).isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前学期没有可导出的考试')));
      return;
    }

    final nameCtrl = TextEditingController(text: '考试存档_$_currentSemester');
    final fileName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出存档'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: '自定义文件名',
            suffixText: '.json',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('确定导出'),
          ),
        ],
      ),
    );

    if (fileName == null || fileName.isEmpty) return;

    try {
      Directory? backupDir;
      if (Platform.isAndroid) {
        backupDir = await getExternalStorageDirectory();
        // 如果想要存到 Download/沈理考试/，这里应该拿到外部存储根目录
        // 但 getExternalStorageDirectory() 给的是 Android/data/...
        // 所以我们需要构造路径
        backupDir = Directory('/storage/emulated/0/Download/沈理考试');
      } else {
        backupDir = await getApplicationDocumentsDirectory();
        backupDir = Directory('${backupDir.path}/沈理考试');
      }

      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final now = DateTime.now();
      final file = File('${backupDir.path}/$fileName.json');

      final exportData = {
        'version': 1,
        'semester': _currentSemester,
        'export_time': now.toIso8601String(),
        'exams': _exams
            .where((e) => e.semester == _currentSemester)
            .map((e) => e.toJson())
            .toList(),
      };

      await file.writeAsString(jsonEncode(exportData));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功存档至：${file.path}'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '分享/打开',
              onPressed: () {
                Share.shareXFiles([XFile(file.path)], text: '沈理校园考试存档导出');
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('导出考试存档失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  Future<void> _importExams() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(content);

        if (data.containsKey('exams') && data['exams'] is List) {
          final List<dynamic> examsJson = data['exams'];
          final List<ExamModel> importedExams = examsJson
              .map((e) => ExamModel.fromJson(e))
              .toList();

          if (mounted) {
            setState(() {
              int addedCount = 0;
              for (var newExam in importedExams) {
                bool exists = _exams.any(
                  (e) =>
                      e.name == newExam.name &&
                      e.startTime == newExam.startTime,
                );
                if (!exists) {
                  _exams.add(newExam);
                  addedCount++;
                }
              }
              _exams.sort((a, b) => a.startTime.compareTo(b.startTime));

              _saveToLocal();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('成功导入 $addedCount 场考试安排！')),
              );
            });
          }
        } else {
          throw Exception('文件格式不正确，缺少考试数据');
        }
      }
    } catch (e) {
      debugPrint('导入考试存档失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  void _syncWidget() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final prefs = await SharedPreferences.getInstance();

        final now = DateTime.now();
        final activeExams = _exams
            .where((e) => e.endTime.isAfter(now))
            .toList();

        final examsJson = activeExams.map((e) {
          final dateStr =
              '${e.startTime.year}-${e.startTime.month.toString().padLeft(2, '0')}-${e.startTime.day.toString().padLeft(2, '0')}';
          final startTimeStr =
              '${e.startTime.hour.toString().padLeft(2, '0')}:${e.startTime.minute.toString().padLeft(2, '0')}';
          final endTimeStr =
              '${e.endTime.hour.toString().padLeft(2, '0')}:${e.endTime.minute.toString().padLeft(2, '0')}';

          final startDate = DateTime(
            e.startTime.year,
            e.startTime.month,
            e.startTime.day,
          );
          final today = DateTime(now.year, now.month, now.day);
          final diffDays = startDate.difference(today).inDays;

          String countdown;
          if (diffDays == 0) {
            countdown = '今天';
          } else if (diffDays == 1) {
            countdown = '明天';
          } else if (diffDays == 2) {
            countdown = '后天';
          } else {
            countdown = '$diffDays天后';
          }

          return {
            'name': e.name,
            'date': dateStr,
            'time': '$startTimeStr-$endTimeStr',
            'location': e.location.isNotEmpty ? e.location : '未指定',
            'countdown': countdown,
          };
        }).toList();

        final jsonStr = jsonEncode(examsJson);
        await prefs.setString('widget_exam_data', jsonStr);

        const channel = MethodChannel('shenliyuan/widget');
        await channel.invokeMethod('updateWidget');
      } catch (e) {
        debugPrint('同步考试小组件失败: $e');
      }
    });
  }

  String _formatExamDuration(DateTime start, DateTime end) {
    if (start.year == end.year &&
        start.month == end.month &&
        start.day == end.day) {
      return '${start.month}月${start.day}日 ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} - ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    } else {
      return '${_formatTime(start)} - ${_formatTime(end)}';
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

  void _showEditDialog([ExamModel? exam, int? index]) {
    final nameCtrl = TextEditingController(text: exam?.name ?? '');
    final locCtrl = TextEditingController(text: exam?.location ?? '');
    String selectedSemester = exam?.semester ?? _currentSemester;

    DateTime examDate = exam?.startTime ?? DateTime.now();
    TimeOfDay startTime = TimeOfDay.fromDateTime(
      exam?.startTime ?? DateTime.now(),
    );
    TimeOfDay endTime = TimeOfDay.fromDateTime(
      exam?.endTime ?? DateTime.now().add(const Duration(hours: 2)),
    );

    final jsonController = TextEditingController();
    bool isAiMode = exam == null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E2235) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            contentPadding: const EdgeInsets.all(24),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    exam == null ? '添加考试' : '编辑考试',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (exam == null) ...[
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('手动添加')),
                        ButtonSegment(value: true, label: Text('AI 导入')),
                      ],
                      selected: {isAiMode},
                      onSelectionChanged: (Set<bool> newSelection) {
                        setModalState(() {
                          isAiMode = newSelection.first;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (isAiMode) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.secondaryContainer.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.lightbulb_outline,
                                size: 16,
                                color: Theme.of(context).colorScheme.secondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '使用步骤',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '1. 点击下方按钮复制提示词；',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '2. 将提示词与考试安排发给AI；',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '3. 在下方粘贴 AI 回复的 JSON 代码。',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('一键复制 AI 提示词'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onPrimaryContainer,
                      ),
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: generateExamPrompt()),
                        );
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
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '科目名称',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedSemester,
                      decoration: const InputDecoration(
                        labelText: '归属学期',
                        border: OutlineInputBorder(),
                      ),
                      items: _availableSemesters
                          .map(
                            (s) => DropdownMenuItem(value: s, child: Text(s)),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null)
                          setModalState(() => selectedSemester = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () async {
                        final date = await showDatePicker(
                          context: ctx,
                          initialDate: examDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (date != null) {
                          setModalState(() {
                            examDate = date;
                          });
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '考试日期',
                          border: OutlineInputBorder(),
                        ),
                        child: Text(
                          '${examDate.year}年${examDate.month}月${examDate.day}日',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final time = await showTimePicker(
                                context: ctx,
                                initialTime: startTime,
                              );
                              if (time != null) {
                                setModalState(() {
                                  startTime = time;
                                  // auto correct endTime if needed
                                  final startMins =
                                      startTime.hour * 60 + startTime.minute;
                                  final endMins =
                                      endTime.hour * 60 + endTime.minute;
                                  if (endMins <= startMins) {
                                    final newEndMins =
                                        startMins +
                                        120; // 2 hours duration default
                                    endTime = TimeOfDay(
                                      hour: (newEndMins ~/ 60) % 24,
                                      minute: newEndMins % 60,
                                    );
                                  }
                                });
                              }
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '开始时间',
                                border: OutlineInputBorder(),
                              ),
                              child: Text(
                                '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final time = await showTimePicker(
                                context: ctx,
                                initialTime: endTime,
                              );
                              if (time != null) {
                                setModalState(() {
                                  endTime = time;
                                });
                              }
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '结束时间',
                                border: OutlineInputBorder(),
                              ),
                              child: Text(
                                '${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: locCtrl,
                      decoration: const InputDecoration(
                        labelText: '考试地点',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          if (isAiMode) {
                            final code = jsonController.text.trim();
                            if (code.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请粘贴 JSON 代码！')),
                              );
                              return;
                            }
                            try {
                              final List dynamicList = jsonDecode(code);
                              final List<ExamModel> newExams = dynamicList.map((
                                e,
                              ) {
                                return ExamModel(
                                  name: e['name'],
                                  startTime: DateTime.parse(e['startTime']),
                                  endTime: DateTime.parse(e['endTime']),
                                  location: e['location'],
                                  semester: _currentSemester,
                                );
                              }).toList();
                              if (mounted)
                                setState(() {
                                  _exams.addAll(newExams);
                                  _exams.sort(
                                    (a, b) =>
                                        a.startTime.compareTo(b.startTime),
                                  );
                                });
                              _saveToLocal();
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('成功导入 ${newExams.length} 场考试！'),
                                ),
                              );
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '解析失败: ${e.toString().split('\n').first}',
                                  ),
                                ),
                              );
                            }
                          } else {
                            if (nameCtrl.text.trim().isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('科目名称不能为空')),
                              );
                              return;
                            }

                            final startDateTime = DateTime(
                              examDate.year,
                              examDate.month,
                              examDate.day,
                              startTime.hour,
                              startTime.minute,
                            );
                            final endDateTime = DateTime(
                              examDate.year,
                              examDate.month,
                              examDate.day,
                              endTime.hour,
                              endTime.minute,
                            );

                            if (endDateTime.isBefore(startDateTime)) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('结束时间不能早于开始时间')),
                              );
                              return;
                            }
                            final newExam = ExamModel(
                              name: nameCtrl.text.trim(),
                              startTime: startDateTime,
                              endTime: endDateTime,
                              location: locCtrl.text.trim(),
                              semester: selectedSemester,
                            );
                            if (mounted)
                              setState(() {
                                if (index != null && exam != null) {
                                  _exams[index] = newExam;
                                } else {
                                  _exams.add(newExam);
                                }
                                _exams.sort(
                                  (a, b) => a.startTime.compareTo(b.startTime),
                                );
                              });
                            _saveToLocal();
                            Navigator.pop(ctx);
                          }
                        },
                        child: Text(
                          exam == null ? (isAiMode ? '导入' : '添加') : '保存修改',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).then((_) {
      nameCtrl.dispose();
      locCtrl.dispose();
      jsonController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final displayExams = _exams
        .where((e) => e.semester == _currentSemester)
        .toList();

    final now = DateTime.now();
    displayExams.sort((a, b) {
      final aPast = a.endTime.isBefore(now);
      final bPast = b.endTime.isBefore(now);
      if (aPast && !bPast) return 1;
      if (!aPast && bPast) return -1;
      return a.startTime.compareTo(b.startTime);
    });
    final availableSemesters = _availableSemesters;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF131720)
          : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _currentSemester,
            dropdownColor: isDark ? const Color(0xFF1E2235) : Colors.white,
            icon: Icon(
              Icons.arrow_drop_down,
              color: isDark ? Colors.white : Colors.black87,
            ),
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black87,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            onChanged: (String? newValue) {
              if (newValue != null) {
                if (mounted)
                  setState(() {
                    _currentSemester = newValue;
                  });
              }
            },
            items: availableSemesters.map<DropdownMenuItem<String>>((
              String value,
            ) {
              return DropdownMenuItem<String>(
                value: value,
                child: Text(
                  value,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black),
                ),
              );
            }).toList(),
            selectedItemBuilder: (BuildContext context) {
              return availableSemesters.map<Widget>((String item) {
                return Center(
                  child: Text(
                    item,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }).toList();
            },
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: '导入存档',
            onPressed: _importExams,
          ),
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '导出存档',
            onPressed: _exportExams,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加考试',
            onPressed: () => _showEditDialog(),
          ),
        ],
      ),
      body: displayExams.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.event_note,
                    size: 64,
                    color: isDark ? Colors.white38 : Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '当前学期暂无考试安排',
                    style: TextStyle(
                      color: isDark ? Colors.white54 : Colors.grey[600],
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击右上角 + 号添加',
                    style: TextStyle(
                      color: isDark ? Colors.white38 : Colors.grey[500],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: displayExams.length,
              itemBuilder: (context, index) {
                final exam = displayExams[index];
                final originalIndex = _exams.indexOf(exam);

                return Dismissible(
                  key: ValueKey(
                    '${exam.name}_${exam.startTime.millisecondsSinceEpoch}_$originalIndex',
                  ),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    margin: const EdgeInsets.only(bottom: 12.0),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (direction) async {
                    return await showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: const Text("确认删除"),
                          content: const Text("确定要删除这场考试吗？"),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text("取消"),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text(
                                "删除",
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                  onDismissed: (direction) {
                    if (mounted)
                      setState(() {
                        _exams.removeAt(originalIndex);
                      });
                    _saveToLocal();
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('已删除 ${exam.name}')));
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _showEditDialog(exam, originalIndex),
                      child: Opacity(
                        opacity: exam.endTime.isBefore(now) ? 0.5 : 1.0,
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
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF1A1A2E),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.access_time,
                                          size: 14,
                                          color: isDark
                                              ? Colors.white54
                                              : Colors.grey[600],
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            _formatExamDuration(
                                              exam.startTime,
                                              exam.endTime,
                                            ),
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: isDark
                                                  ? Colors.white70
                                                  : Colors.grey[700],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF6366F1,
                                  ).withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  children: [
                                    const Icon(
                                      Icons.location_on,
                                      color: Color(0xFF6366F1),
                                      size: 16,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      exam.location.isNotEmpty
                                          ? exam.location
                                          : '未指定',
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
                                icon: Icon(
                                  Icons.edit_calendar,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.grey[600],
                                ),
                                tooltip: '添加到系统日历',
                                onPressed: () => _addToCalendar(exam),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
