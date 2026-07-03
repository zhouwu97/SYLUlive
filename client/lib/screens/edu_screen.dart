import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../utils/app_navigator.dart' show appNavigatorKey;
import '../features/campus_data/evaluation/evaluation_screen.dart';
import 'edu_grade_screen.dart';

class EduScreen extends StatefulWidget {
  const EduScreen({super.key});

  @override
  State<EduScreen> createState() => _EduScreenState();
}

class _EduScreenState extends State<EduScreen> {
  final _studentIdController = TextEditingController();
  final _passwordController = TextEditingController();
  static const Duration _courseFetchTimeout = Duration(seconds: 25);

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
  void dispose() {
    _studentIdController.dispose();
    _passwordController.dispose();
    super.dispose();
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              // 状态信息卡
              Card(
                elevation: 0,
                color: isDark ? Colors.grey[850] : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: isDark ? Colors.transparent : Colors.grey.withValues(alpha: 0.2)),
                ),
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
                            size: 36,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  eduProvider.isBound ? '已绑定教务账号' : '未绑定教务账号',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (eduProvider.isBound)
                                  Text(
                                    '学号: ${eduProvider.studentId}',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (eduProvider.isBound) ...[
                        const SizedBox(height: 12),
                        Text(
                          '${eduProvider.grade.isNotEmpty ? eduProvider.grade : "未知"}级 · ${eduProvider.college.isNotEmpty ? eduProvider.college : "未知"}',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.grey[300] : Colors.grey[800],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          eduProvider.major.isNotEmpty ? eduProvider.major : "未知",
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.grey[400] : Colors.grey[600],
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => _showBindDialog(context, eduProvider),
                          icon: const Icon(Icons.link),
                          label: const Text('绑定教务'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              if (eduProvider.isBound) ...[
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 12),
                  child: Text(
                    '教务功能',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildActionCard(
                        context: context,
                        icon: Icons.schedule,
                        iconColor: Colors.blue,
                        title: '课表',
                        onTap: () => _showCourseDialog(context, eduProvider),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildActionCard(
                        context: context,
                        icon: Icons.star,
                        iconColor: Colors.orange,
                        title: '成绩',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const EduGradeScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildActionCard(
                        context: context,
                        icon: Icons.rate_review,
                        iconColor: Colors.purple,
                        title: '教学评价',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const EvaluationScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[900] : Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '绑定教务账号后，可以查看课表、成绩和教学评价',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              if (eduProvider.isBound) ...[
                const SizedBox(height: 32),
                Center(
                  child: TextButton.icon(
                    onPressed: () => _showUnbindDialog(context, eduProvider),
                    icon: const Icon(Icons.link_off, size: 16),
                    label: const Text('解绑教务账号', style: TextStyle(fontSize: 14)),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildActionCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? Colors.grey[850] : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isDark ? Colors.transparent : Colors.grey.withValues(alpha: 0.1)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 24, color: iconColor),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey[300] : Colors.grey[800],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBindDialog(BuildContext context, EduProvider eduProvider) {
    _studentIdController.clear();
    _passwordController.clear();
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
                controller: _studentIdController,
                decoration: const InputDecoration(
                  labelText: '教务学号',
                  hintText: '请输入10位学号',
                ),
                maxLength: 10,
                enabled: !isBinding,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: '教务密码'),
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
                        _studentIdController.text,
                        _passwordController.text,
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                        if (success) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('绑定成功')));
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(eduProvider.errorMessage ?? '绑定失败'),
                            ),
                          );
                        }
                      }
                    },
              child: isBinding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
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
                    content: Text(
                      result.success ? '解绑成功' : (result.errorMessage ?? '解绑失败'),
                    ),
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
                items: () {
                  int startYear = eduProvider.enrollmentYear;
                  int currentYear = DateTime.now().year;
                  int count = (currentYear - startYear) + 2;
                  if (count < 1) count = 1;

                  return List.generate(count, (i) {
                    int year = startYear + i;
                    return DropdownMenuItem(
                      value: year.toString(),
                      child: Text('$year-${year + 1}'),
                    );
                  }).reversed.toList();
                }(),
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
                      try {
                        final result = await eduProvider
                            .getCourses(selectedYear, selectedSemester)
                            .timeout(_courseFetchTimeout);
                        if (context.mounted) {
                          Navigator.pop(context); // 请求结束后关闭对话框
                          if (result != null &&
                              result.success &&
                              result.data != null) {
                            _showCoursesResult(
                              context,
                              result.data!,
                              selectedYear,
                              selectedSemester,
                              eduProvider,
                            );
                          } else {
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  result?.errorMessage ??
                                      '获取课表失败，请稍后重试或重新绑定教务账号',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      } on TimeoutException {
                        if (context.mounted) {
                          Navigator.pop(context);
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                '获取课表超过 ${_courseFetchTimeout.inSeconds} 秒，请稍后重试',
                              ),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          Navigator.pop(context);
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('获取课表异常：$e'),
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
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('查询'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCoursesResult(
    BuildContext context,
    List<Map<String, dynamic>> courses,
    String year,
    int semester,
    EduProvider eduProvider,
  ) {
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
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
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
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
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
                      final sc = Provider.of<CourseScheduleProvider>(
                        navContext,
                        listen: false,
                      );
                      sc.setSemester(year, semester);
                      await sc.applyFetchedCourses(courses);
                      unawaited(
                        eduProvider.syncCourses(year, semester, courses).then((
                          success,
                        ) {
                          if (!success) {
                            debugPrint('课表已本地导入，后台同步到服务器失败，等待下次刷新重试');
                          }
                        }).catchError((Object error, StackTrace stackTrace) {
                          debugPrint('课表后台同步异常: $error\n$stackTrace');
                          return null;
                        }),
                      );
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            '导入课表成功。首次导入请到课表页点击“设置周数”，选择开学第一天。',
                          ),
                          backgroundColor: Colors.green,
                          duration: Duration(seconds: 4),
                        ),
                      );
                      Navigator.of(navContext).maybePop();
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
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
