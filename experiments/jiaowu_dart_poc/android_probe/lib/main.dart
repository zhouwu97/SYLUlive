import 'package:flutter/material.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

void main() {
  runApp(const JiaowuProbeApp());
}

class JiaowuProbeApp extends StatelessWidget {
  const JiaowuProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jiaowu Android Probe',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ProbeHomePage(),
    );
  }
}

class ProbeHomePage extends StatefulWidget {
  const ProbeHomePage({super.key});

  @override
  State<ProbeHomePage> createState() => _ProbeHomePageState();
}

class _ProbeHomePageState extends State<ProbeHomePage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _logBuffer = StringBuffer();

  JiaowuClient? _client;
  bool _isLoading = false;

  void _log(String message) {
    setState(() {
      _logBuffer.writeln('[${DateTime.now().toString().substring(11, 19)}] $message');
    });
  }

  Future<void> _runProbe() async {
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      _log('错误: 请输入学号和密码');
      return;
    }

    setState(() {
      _isLoading = true;
      _logBuffer.clear();
    });

    try {
      _client = JiaowuClient();
      _log('开始登录...');

      await _client!.login(
        studentId: _usernameController.text,
        password: _passwordController.text,
      );
      _log('✓ 登录成功');

      _log('获取 Profile...');
      final profile = await _client!.getProfile();
      _log('✓ Profile: ${profile.name} - ${profile.grade} ${profile.major}');

      _log('获取成绩列表...');
      final gradeResult = await _client!.getGrades(
        year: '2025',
        semester: 12,
      );
      _log('✓ 成绩列表: ${gradeResult.grades.length} 条');

      if (gradeResult.grades.isEmpty) {
        _log('警告: 没有成绩记录');
        return;
      }

      // 查询前两门课程的成绩详情
      final validGrades = gradeResult.grades
          .where((g) =>
              (g.raw['jxb_id'] as String? ?? '').isNotEmpty &&
              (g.raw['kcmc'] as String? ?? '').isNotEmpty)
          .take(2)
          .toList();

      if (validGrades.isEmpty) {
        _log('警告: 没有有效成绩记录');
        return;
      }

      _log('开始查询成绩详情 (${validGrades.length} 门课程)...');

      for (var i = 0; i < validGrades.length; i++) {
        final grade = validGrades[i];
        final courseName = grade.raw['kcmc'] as String? ?? '';
        final year = grade.raw['xnm'] as String? ?? '';
        final semester = int.tryParse(grade.raw['xqm']?.toString() ?? '') ?? 0;
        final classId = grade.raw['jxb_id'] as String? ?? '';
        final courseId = grade.raw['kch_id'] as String? ?? '';
        final studentGradeId = grade.raw['xh_id'] as String? ?? '';

        _log('查询课程 ${i + 1}: $courseName');

        try {
          final detail = await _client!.getGradeDetail(
            year: year,
            semester: semester,
            classId: classId,
            courseName: courseName,
            courseId: courseId.isEmpty ? null : courseId,
            studentGradeId: studentGradeId.isEmpty ? null : studentGradeId,
          );

          _log('  ✓ 总评: ${detail.totalGrade}');
          _log('  ✓ 分项数: ${detail.components.length}');
          for (final comp in detail.components) {
            _log('    - ${comp.name}: ${comp.score} ${comp.weight ?? ""}');
          }
        } catch (e) {
          _log('  ✗ 查询失败: $e');
        }
      }

      _log('');
      _log('========================================');
      _log('✓ Android Probe 完成');
      _log('========================================');
    } catch (e, stackTrace) {
      _log('✗ 错误: $e');
      _log('Stack trace: $stackTrace');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Jiaowu Android Probe'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: '学号',
                border: OutlineInputBorder(),
              ),
              enabled: !_isLoading,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _isLoading ? null : _runProbe,
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('运行 Probe'),
            ),
            const SizedBox(height: 24),
            const Text(
              '日志',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.black,
                ),
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: Text(
                    _logBuffer.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.greenAccent,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
