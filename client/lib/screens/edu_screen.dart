import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../utils/app_navigator.dart' show appNavigatorKey;
import '../features/campus_data/evaluation/evaluation_screen.dart';
import 'edu_grade_screen.dart';
import '../widgets/campus/campus_theme.dart';

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
      backgroundColor: isDark ? CampusTheme.darkBg : CampusTheme.bg,
      appBar: AppBar(
        title: Text(
          '教务系统',
          style: TextStyle(
            color: isDark ? Colors.white : CampusTheme.text,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(
          color: isDark ? Colors.white : CampusTheme.text,
        ),
      ),
      body: Consumer<EduProvider>(
        builder: (context, eduProvider, child) {
          if (eduProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              _buildEduStatusCard(context, eduProvider, isDark),
              if (eduProvider.isBound) ...[
                const SizedBox(height: 24),
                _buildEduActionGrid(context, eduProvider, isDark),
              ],
              const SizedBox(height: 24),
              _buildEduHint(isDark),
              if (eduProvider.isBound) ...[
                const SizedBox(height: 32),
                _buildDangerUnbindButton(context, eduProvider, isDark),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildEduStatusCard(BuildContext context, EduProvider eduProvider, bool isDark) {
    return Container(
      decoration: CampusTheme.cardDecoration(isDark),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: eduProvider.isBound
                      ? CampusTheme.green.withValues(alpha: 0.12)
                      : CampusTheme.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  eduProvider.isBound ? Icons.check_circle_rounded : Icons.warning_rounded,
                  color: eduProvider.isBound ? CampusTheme.green : CampusTheme.orange,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eduProvider.isBound ? '已绑定教务账号' : '未绑定教务账号',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : CampusTheme.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (eduProvider.isBound)
                      Text(
                        '学号: ${eduProvider.studentId}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: CampusTheme.subText,
                        ),
                      )
                    else
                      const Text(
                        '绑定后可使用完整功能',
                        style: const TextStyle(
                          fontSize: 13,
                          color: CampusTheme.subText,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (eduProvider.isBound) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${eduProvider.grade.isNotEmpty ? eduProvider.grade : "未知"}级 · ${eduProvider.college.isNotEmpty ? eduProvider.college : "未知"}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white70 : CampusTheme.text.withValues(alpha: 0.85),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          eduProvider.major.isNotEmpty ? eduProvider.major : "未知",
                          style: const TextStyle(
                            fontSize: 12,
                            color: CampusTheme.subText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _showBindDialog(context, eduProvider),
              icon: const Icon(Icons.link_rounded, size: 20),
              label: const Text('立即绑定教务', style: TextStyle(fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: CampusTheme.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(double.infinity, 46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEduActionGrid(BuildContext context, EduProvider eduProvider, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            '教务功能',
            style: TextStyle(
              fontSize: 16, 
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : CampusTheme.text,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _buildActionCard(
                context: context,
                icon: Icons.schedule_rounded,
                iconColor: CampusTheme.blue,
                title: '课表',
                onTap: () => _showCourseDialog(context, eduProvider),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionCard(
                context: context,
                icon: Icons.star_rounded,
                iconColor: CampusTheme.orange,
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
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionCard(
                context: context,
                icon: Icons.rate_review_rounded,
                iconColor: CampusTheme.cyan,
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
    );
  }

  Widget _buildEduHint(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: CampusTheme.cardDecoration(isDark),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: CampusTheme.subText,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '绑定教务账号后，可以查看课表、成绩和教学评价',
              style: const TextStyle(
                fontSize: 12.5,
                color: CampusTheme.subText,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDangerUnbindButton(BuildContext context, EduProvider eduProvider, bool isDark) {
    return Center(
      child: TextButton.icon(
        onPressed: () => _showUnbindDialog(context, eduProvider),
        icon: const Icon(Icons.link_off_rounded, size: 18, color: CampusTheme.red),
        label: const Text(
          '解绑教务账号', 
          style: const TextStyle(
            fontSize: 14, 
            fontWeight: FontWeight.w600,
            color: CampusTheme.red,
          )
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          backgroundColor: CampusTheme.red.withValues(alpha: 0.1),
        ),
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
      color: isDark ? CampusTheme.darkCard : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 86,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.08) : CampusTheme.softBorder,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : CampusTheme.text,
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
                      await sc.selectTerm(year, semester);
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
