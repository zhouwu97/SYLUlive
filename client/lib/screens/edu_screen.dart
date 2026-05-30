import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../utils/app_navigator.dart' show appNavigatorKey;

class EduScreen extends StatefulWidget {
  const EduScreen({super.key});

  @override
  State<EduScreen> createState() => _EduScreenState();
}

class _EduScreenState extends State<EduScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = context.read<AuthProvider>();
      final eduProvider = context.read<EduProvider>();
      if (authProvider.user != null) {
        eduProvider.setUserId(authProvider.user!.id.toString());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('教务系统'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Consumer<EduProvider>(
        builder: (context, eduProvider, child) {
          if (eduProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          return ListView(
            children: [
              Card(
                margin: const EdgeInsets.all(16),
                color: isDark ? Colors.grey[850] : Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            eduProvider.isBound ? Icons.check_circle : Icons.warning,
                            color: eduProvider.isBound ? Colors.green : Colors.orange,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                eduProvider.isBound ? '已绑定教务账号' : '未绑定教务账号',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (eduProvider.isBound)
                                Text(
                                  '学号: ${eduProvider.studentId}',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (eduProvider.isBound)
                        Text(
                          '年级: ${eduProvider.grade.isNotEmpty ? eduProvider.grade : "未知"} | '
                          '学院: ${eduProvider.college.isNotEmpty ? eduProvider.college : "未知"} | '
                          '专业: ${eduProvider.major.isNotEmpty ? eduProvider.major : "未知"}',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          if (eduProvider.isBound)
                            ElevatedButton.icon(
                              onPressed: () => _showUnbindDialog(context, eduProvider),
                              icon: const Icon(Icons.link_off),
                              label: const Text('解绑'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                              ),
                            )
                          else
                            ElevatedButton.icon(
                              onPressed: () => _showBindDialog(context, eduProvider),
                              icon: const Icon(Icons.link),
                              label: const Text('绑定教务'),
                            ),
                          const SizedBox(width: 8),
                          if (eduProvider.isBound)
                            OutlinedButton.icon(
                              onPressed: () => _showCourseDialog(context, eduProvider),
                              icon: const Icon(Icons.schedule),
                              label: const Text('课表'),
                            ),
                          const SizedBox(width: 8),
                          if (eduProvider.isBound)
                            OutlinedButton.icon(
                              onPressed: () => _showGradesDialog(context, eduProvider),
                              icon: const Icon(Icons.grade),
                              label: const Text('成绩'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('功能说明'),
                subtitle: Text('绑定教务账号后，可以查看课表和成绩'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showBindDialog(BuildContext context, EduProvider eduProvider) {
    final studentIdController = TextEditingController();
    final passwordController = TextEditingController();
    bool isBinding = false; // 本地加载状态

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('绑定教务账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: studentIdController,
                decoration: const InputDecoration(
                  labelText: '教务学号',
                  hintText: '请输入10位学号',
                ),
                maxLength: 10,
                enabled: !isBinding,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                decoration: const InputDecoration(
                  labelText: '教务密码',
                ),
                obscureText: true,
                enabled: !isBinding,
              ),
              if (isBinding) ...[
                const SizedBox(height: 20),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('正在连接教务系统...', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: isBinding ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: isBinding
                  ? null
                  : () async {
                      setDialogState(() => isBinding = true);
                      final success = await eduProvider.bind(
                        studentIdController.text,
                        passwordController.text,
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                        if (success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('绑定成功')),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(eduProvider.errorMessage ?? '绑定失败')),
                          );
                        }
                      }
                    },
              child: isBinding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('绑定'),
            ),
          ],
        ),
      ),
    );
  }

  void _showUnbindDialog(BuildContext context, EduProvider eduProvider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认解绑'),
        content: const Text('解绑后将在本设备清除教务账号信息，确定要解绑吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final result = await eduProvider.unbind();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(result.success ? '解绑成功' : (result.errorMessage ?? '解绑失败')),
                    backgroundColor: result.success ? Colors.green : Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
  }

  void _showCourseDialog(BuildContext context, EduProvider eduProvider) {
    final now = DateTime.now();
    int currentYear = now.year;
    String selectedYear;
    int selectedSemester;
    bool isFetching = false;
    
    if (now.month >= 2 && now.month <= 7) {
      selectedYear = (currentYear - 1).toString();
      selectedSemester = 12; // 春季（第二学期）
    } else if (now.month == 1) {
      selectedYear = (currentYear - 1).toString();
      selectedSemester = 3; // 秋季（第一学期）
    } else {
      selectedYear = currentYear.toString();
      selectedSemester = 3; // 秋季（第一学期）
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
        title: const Text('选择学期'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: selectedYear,
              decoration: const InputDecoration(labelText: '学年'),
              items: List.generate(5, (i) {
                int year = DateTime.now().year - i;
                return DropdownMenuItem(
                  value: year.toString(),
                  child: Text('$year-${year + 1}'),
                );
              }),
              onChanged: (value) {
                selectedYear = value ?? selectedYear;
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              value: selectedSemester,
              decoration: const InputDecoration(labelText: '学期'),
              items: const [
                DropdownMenuItem(value: 3, child: Text('第一学期')),
                DropdownMenuItem(value: 12, child: Text('第二学期')),
              ],
              onChanged: (value) {
                selectedSemester = value ?? selectedSemester;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: isFetching ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: isFetching
                ? null
                : () async {
                    setDialogState(() => isFetching = true);
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final result = await eduProvider.getCourses(selectedYear, selectedSemester);
                    if (context.mounted) {
                      Navigator.pop(context); // 请求结束后关闭对话框
                      if (result != null && result.success && result.data != null) {
                        _showCoursesResult(context, result.data!, selectedYear, selectedSemester, eduProvider);
                      } else {
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(result?.errorMessage ?? '获取课表失败'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
            child: isFetching
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('查询'),
          ),
        ],
      ),
    ),
  );
  }

  void _showCoursesResult(BuildContext context, List<Map<String, dynamic>> courses, String year, int semester, EduProvider eduProvider) {
    showModalBottomSheet(
      context: appNavigatorKey.currentContext!,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${year}-${(int.parse(year) + 1).toString()} ${semester == 3 ? "第一学期" : "第二学期"} 课表',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: courses.isEmpty
                  ? const Center(child: Text('暂无课表'))
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: courses.length,
                      itemBuilder: (ctx, index) {
                        final course = courses[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          child: ListTile(
                            title: Text(course['name'] ?? ''),
                            subtitle: Text(
                              '教师: ${course['teacher'] ?? '-'} | '
                              '地点: ${course['location'] ?? '-'} | '
                              '时间: 第${course['time'] ?? 0}节 | '
                              '星期: ${course['week_day'] ?? 0}',
                            ),
                          ),
                        );
                      },
                    ),
            ),
            // 导入到课表按钮
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    // 先拿到全局 ScaffoldMessenger（此时 context 还活着）
                    final navContext = appNavigatorKey.currentContext;
                    if (navContext == null) return;
                    final messenger = ScaffoldMessenger.of(navContext);
                    Navigator.pop(ctx); // 关闭底部弹窗
                    try {
                      final success = await eduProvider.syncCourses(year, semester, courses);
                      if (success) {
                        final navContext = appNavigatorKey.currentContext;
                        if (navContext != null) {
                          final sc = Provider.of<CourseScheduleProvider>(navContext, listen: false);
                          sc.setSemester(year, semester);
                          sc.applyFetchedCourses(courses);
                        }
                      }
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(success ? '导入课表成功喵~' : '导入失败，请重试'),
                          backgroundColor: success ? Colors.green : Colors.red,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text('导入出错: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('导入到课表', style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showGradesDialog(BuildContext context, EduProvider eduProvider) {
    final now = DateTime.now();
    int currentYear = now.year;
    String selectedYear;
    int selectedSemester;
    bool isFetching = false;
    
    if (now.month >= 2 && now.month <= 7) {
      selectedYear = (currentYear - 1).toString();
      selectedSemester = 12; // 春季（第二学期）
    } else if (now.month == 1) {
      selectedYear = (currentYear - 1).toString();
      selectedSemester = 3; // 秋季（第一学期）
    } else {
      selectedYear = currentYear.toString();
      selectedSemester = 3; // 秋季（第一学期）
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
        title: const Text('选择学期'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: selectedYear,
              decoration: const InputDecoration(labelText: '学年'),
              items: List.generate(5, (i) {
                int year = DateTime.now().year - i;
                return DropdownMenuItem(
                  value: year.toString(),
                  child: Text('$year-${year + 1}'),
                );
              }),
              onChanged: (value) {
                selectedYear = value ?? selectedYear;
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              value: selectedSemester,
              decoration: const InputDecoration(labelText: '学期'),
              items: const [
                DropdownMenuItem(value: 3, child: Text('第一学期')),
                DropdownMenuItem(value: 12, child: Text('第二学期')),
              ],
              onChanged: (value) {
                selectedSemester = value ?? selectedSemester;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: isFetching ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: isFetching
                ? null
                : () async {
                    setDialogState(() => isFetching = true);
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final result = await eduProvider.getGrades(selectedYear, selectedSemester);
                    if (context.mounted) {
                      Navigator.pop(context); // 请求结束后关闭对话框
                      if (result != null && result.success && result.data != null) {
                        _showGradesResult(context, result.data!, selectedYear, selectedSemester);
                      } else {
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(result?.errorMessage ?? '获取成绩失败'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
            child: isFetching
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('查询'),
          ),
        ],
      ),
    ),
  );
  }

  void _showGradesResult(BuildContext context, List<Map<String, dynamic>> grades, String year, int semester) {
    showModalBottomSheet(
      context: appNavigatorKey.currentContext!,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${year}-${(int.parse(year) + 1).toString()} ${semester == 3 ? "第一学期" : "第二学期"} 成绩',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: grades.isEmpty
                  ? const Center(child: Text('暂无成绩'))
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: grades.length,
                      itemBuilder: (context, index) {
                        final grade = grades[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          child: ListTile(
                            title: Text(grade['name'] ?? ''),
                            subtitle: Text(
                              '成绩: ${grade['grade'] ?? '-'} | '
                              '学分: ${grade['credits'] ?? 0} | '
                              '绩点: ${grade['gpa'] ?? 0}',
                            ),
                            trailing: grade['is_degree'] == true
                                ? const Chip(label: Text('学位课'))
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}