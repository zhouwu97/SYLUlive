import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/application/academic_login_coordinator.dart';
import '../features/academic/presentation/academic_login_dialog.dart';
import '../features/campus_data/evaluation/evaluation_screen.dart';
import 'edu_grade_screen.dart';
import '../widgets/campus/campus_theme.dart';
import '../widgets/course/course_import_sheet.dart';
import '../widgets/course/course_preview_sheet.dart';

class EduScreen extends StatefulWidget {
  const EduScreen({super.key});

  @override
  State<EduScreen> createState() => _EduScreenState();
}

class _EduScreenState extends State<EduScreen> {
  final _studentIdController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = context.read<AuthProvider>();
      final eduProvider = context.read<EduProvider>();
      if (authProvider.user != null) {
        eduProvider.setUserId(authProvider.user!.id.toString());
      }
      _tryAutoLogin();
    });
  }

  Future<void> _tryAutoLogin() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn || auth.user == null) return;
    final coordinator = _coordinatorOrNull();
    if (coordinator == null) return;
    if (!await coordinator.hasSavedCredential()) return;
    final outcome = await coordinator.ensureAuthenticated();
    if (!mounted || !outcome.isSuccess) return;
    await context.read<EduProvider>().refreshStatus();
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

  Widget _buildEduStatusCard(
      BuildContext context, EduProvider eduProvider, bool isDark) {
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
                  eduProvider.isBound
                      ? Icons.check_circle_rounded
                      : Icons.warning_rounded,
                  color: eduProvider.isBound
                      ? CampusTheme.green
                      : CampusTheme.orange,
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
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : const Color(0xFFF8F9FA),
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
                            color: isDark
                                ? Colors.white70
                                : CampusTheme.text.withValues(alpha: 0.85),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          eduProvider.major.isNotEmpty
                              ? eduProvider.major
                              : "未知",
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
              label: const Text('立即绑定教务',
                  style: TextStyle(fontWeight: FontWeight.w700)),
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

  Widget _buildEduActionGrid(
      BuildContext context, EduProvider eduProvider, bool isDark) {
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

  Widget _buildDangerUnbindButton(
      BuildContext context, EduProvider eduProvider, bool isDark) {
    return Center(
      child: TextButton.icon(
        onPressed: () => _showUnbindDialog(context, eduProvider),
        icon: const Icon(Icons.link_off_rounded,
            size: 18, color: CampusTheme.red),
        label: const Text('解绑教务账号',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CampusTheme.red,
            )),
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
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : CampusTheme.softBorder,
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

  Future<void> _showBindDialog(
    BuildContext context,
    EduProvider eduProvider,
  ) async {
    final controller = context.read<AcademicSessionController>();
    final success = await AcademicLoginDialog.show(
      context,
      controller: controller,
      coordinator: _coordinatorOrNull(),
    );
    if (!context.mounted || success != true) return;
    await eduProvider.refreshStatus();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本机教务会话已建立')),
      );
    }
  }

  AcademicLoginCoordinator? _coordinatorOrNull() {
    try {
      return context.read<AcademicLoginCoordinator>();
    } on ProviderNotFoundException {
      return null;
    }
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

  Future<void> _showCourseDialog(
      BuildContext context, EduProvider eduProvider) async {
    final result = await CourseImportSheet.show(
      context,
      eduProvider: eduProvider,
    );
    if (result == null || !context.mounted) return;

    final confirm = await CoursePreviewSheet.show(
      context,
      courses: result.courses,
      year: result.year,
      semester: result.semester,
      eduProvider: eduProvider,
    );

    if (confirm != true || !context.mounted) return;

    final sc = context.read<CourseScheduleProvider>();
    await sc.selectTerm(result.year, result.semester, clearCurrent: true);
    await sc.applyFetchedCourses(result.courses);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已导入，可到课表页查看'),
          backgroundColor: CampusTheme.primary,
        ),
      );
    }
  }
}
