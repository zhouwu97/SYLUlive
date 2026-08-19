import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import 'dart:io' show File;
import 'admin_reports_screen.dart';
import 'admin_candidates_screen.dart';
import 'admin_review_tasks_screen.dart';
import 'admin_featured_applications_screen.dart';
import 'admin_logs_screen.dart';
import 'admin_announcements_screen.dart';
import 'admin_water_sections_screen.dart';
import 'admin_water_icon_review_screen.dart';
import 'exam_papers/admin_exam_papers_screen.dart';
import 'shuitie_screen.dart';
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  bool _isLoading = true;

  // Pending counts
  int? _reportsCount;
  int? _featuredCount;
  int? _reviewTasksCount; // Teachers + Majors
  int? _adminTasksCount; // Invitations + Removals
  int? _examPapersCount; // Exam paper submissions

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCounts());
  }

  Future<void> _loadCounts() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final dio = context.read<AuthProvider>().dio;
      final futures = await Future.wait([
        dio.get('/reports', queryParameters: {'status': 'pending'}),
        dio.get('/admin/featured-applications'),
        dio.get('/teachers/pending'),
        dio.get('/majors/pending'),
        dio.get('/admin/invitations/pending'),
        dio.get('/admin/removals/pending'),
        dio.get('/admin/exam-papers/pending-count'),
      ].map((f) => f.catchError((_) =>
          Response(requestOptions: RequestOptions(path: ''), data: []))));

      if (!mounted) return;

      int getCount(Response res) {
        if (res.data is List) return (res.data as List).length;
        return 0;
      }

      setState(() {
        _reportsCount = getCount(futures[0]);
        _featuredCount = getCount(futures[1]);
        _reviewTasksCount = getCount(futures[2]) + getCount(futures[3]);
        _adminTasksCount = getCount(futures[4]) + getCount(futures[5]);
        _examPapersCount = futures[6].data is Map
            ? ((futures[6].data as Map)['count'] as num?)?.toInt() ?? 0
            : 0;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final bottomSafe = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            title: const Text('管理员面板'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            systemOverlayStyle: (isDark
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark)
                .copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            ),
          ),
          body: Stack(
            children: [
              Positioned.fill(
                  child: _buildBackground(context, themeProvider, isDark)),
              SafeArea(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, 8, 16, bottomSafe + 24),
                  children: [
                    _buildPendingSection(isDark),
                    const SizedBox(height: 18),
                    _AdminSectionGroup(
                      title: '社区治理',
                      isDark: isDark,
                      children: [
                        _AdminActionPill(
                          icon: Icons.gavel,
                          iconColor: Colors.orange,
                          title: '举报处理',
                          subtitle: '内容投诉与违规处理',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminReportsScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.forum_outlined,
                          iconColor: Colors.blue,
                          title: '水帖版块',
                          subtitle: '版主、标签、禁言与日志',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminWaterSectionsScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.star_border,
                          iconColor: Colors.amber,
                          title: '精华申请',
                          subtitle: '内容推荐与审核',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminFeaturedApplicationsScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.image_search,
                          iconColor: Colors.deepPurple,
                          title: '版块图标审核',
                          subtitle: '版主上传图标审核',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminWaterIconReviewScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.history,
                          iconColor: Colors.teal,
                          title: '操作日志',
                          subtitle: '管理员处理记录',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const AdminLogsScreen()))
                              .then((_) => _loadCounts()),
                        ),
                      ],
                    ),
                    _AdminSectionGroup(
                      title: '审核代办',
                      isDark: isDark,
                      children: [
                        _AdminActionPill(
                          icon: Icons.person_search,
                          iconColor: Colors.indigo,
                          title: '教师审核',
                          subtitle: '教师词条提交审核',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminReviewTasksScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.library_books_outlined,
                          iconColor: Colors.deepOrange,
                          title: '试卷审核',
                          subtitle: '待审核与已发布试卷管理',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminExamPapersScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.school_outlined,
                          iconColor: Colors.pink,
                          title: '专业审核',
                          subtitle: '专业信息提交审核',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminReviewTasksScreen()))
                              .then((_) => _loadCounts()),
                        ),
                      ],
                    ),
                    _AdminSectionGroup(
                      title: '管理员协作',
                      isDark: isDark,
                      children: [
                        _AdminActionPill(
                          icon: Icons.group_add_outlined,
                          iconColor: Colors.purple,
                          title: '管理员候选',
                          subtitle: '搜索并邀请普通用户',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminCandidatesScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.how_to_reg,
                          iconColor: Colors.green,
                          title: '邀请 / 罢免',
                          subtitle: '管理员协作代办',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminReviewTasksScreen()))
                              .then((_) => _loadCounts()),
                        ),
                      ],
                    ),
                    _AdminSectionGroup(
                      title: '系统运营',
                      isDark: isDark,
                      children: [
                        _AdminActionPill(
                          icon: Icons.campaign_outlined,
                          iconColor: Colors.redAccent,
                          title: '公告管理',
                          subtitle: '系统公告与通知',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const AdminAnnouncementsScreen()))
                              .then((_) => _loadCounts()),
                        ),
                        _AdminActionPill(
                          icon: Icons.card_giftcard,
                          iconColor: Colors.orange,
                          title: '签到弹窗预览',
                          subtitle: '预览用户签到成功的展示效果',
                          isDark: isDark,
                          onTap: () {
                            HapticFeedback.lightImpact();
                            showGeneralDialog(
                              context: context,
                              barrierDismissible: false,
                              barrierLabel: '签到成功',
                              barrierColor: Colors.black.withValues(alpha: 0.42),
                              transitionDuration: const Duration(milliseconds: 220),
                              pageBuilder: (_, __, ___) {
                                return const CheckInSuccessDialog(
                                  streakDays: 49,
                                  earnedExp: 15,
                                );
                              },
                              transitionBuilder: (_, animation, __, child) {
                                final curved = CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutBack,
                                  reverseCurve: Curves.easeIn,
                                );

                                return FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: Tween<double>(
                                      begin: 0.92,
                                      end: 1,
                                    ).animate(curved),
                                    child: child,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ));
  }

  Widget _buildPendingSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
          child: Text(
            '待处理',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _AdminMetricPill(
              title: '举报',
              count: _reportsCount,
              isLoading: _isLoading,
              isDark: isDark,
              onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminReportsScreen()))
                  .then((_) => _loadCounts()),
            ),
            _AdminMetricPill(
              title: '精华',
              count: _featuredCount,
              isLoading: _isLoading,
              isDark: isDark,
              onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              const AdminFeaturedApplicationsScreen()))
                  .then((_) => _loadCounts()),
            ),
            _AdminMetricPill(
              title: '审核',
              count: _reviewTasksCount,
              isLoading: _isLoading,
              isDark: isDark,
              onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminReviewTasksScreen()))
                  .then((_) => _loadCounts()),
            ),
            _AdminMetricPill(
              title: '试卷',
              count: _examPapersCount,
              isLoading: _isLoading,
              isDark: isDark,
              onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminExamPapersScreen()))
                  .then((_) => _loadCounts()),
            ),
            _AdminMetricPill(
              title: '管理员代办',
              count: _adminTasksCount,
              isLoading: _isLoading,
              isDark: isDark,
              onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminReviewTasksScreen()))
                  .then((_) => _loadCounts()),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBackground(
      BuildContext context, ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.shouldShowCustomBackground &&
        themeProvider.getCustomBackgroundImageFor(context) != null) {
      final bgPath = themeProvider.getCustomBackgroundImageFor(context)!;
      return Stack(
        fit: StackFit.expand,
        children: [
          ThemeProvider.isBundledAssetBackground(bgPath)
              ? Image.asset(ThemeProvider.resolveBundledAssetPath(bgPath),
                  fit: BoxFit.cover)
              : ThemeProvider.isLocalFileBackground(bgPath)
                  ? Image.file(File(bgPath), fit: BoxFit.cover)
                  : Image.network(bgPath, fit: BoxFit.cover),
          Container(
              color: isDark
                  ? Colors.black.withOpacity(0.4)
                  : Colors.white.withOpacity(0.3)),
        ],
      );
    }
    return ColoredBox(
        color: isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight);
  }
}

class _AdminSectionGroup extends StatelessWidget {
  final String title;
  final bool isDark;
  final List<Widget> children;

  const _AdminSectionGroup({
    required this.title,
    required this.isDark,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 18, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: children.length,
          separatorBuilder: (context, index) => const SizedBox(height: 8),
          itemBuilder: (context, index) => children[index],
        ),
      ],
    );
  }
}

class _AdminActionPill extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _AdminActionPill({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.06)
              : Colors.white.withOpacity(0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark ? Colors.white10 : Colors.white,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white54 : Colors.grey[600],
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: isDark ? Colors.white30 : Colors.grey[400],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminMetricPill extends StatelessWidget {
  final String title;
  final int? count;
  final bool isLoading;
  final bool isDark;
  final VoidCallback onTap;

  const _AdminMetricPill({
    required this.title,
    required this.count,
    required this.isLoading,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    String displayCount = '--';
    if (!isLoading && count != null) {
      displayCount = count.toString();
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.08)
              : Colors.white.withOpacity(0.6),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey[200],
                borderRadius: BorderRadius.circular(10),
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : Text(
                      displayCount,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black54,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
