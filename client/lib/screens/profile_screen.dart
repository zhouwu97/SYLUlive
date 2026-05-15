import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/edu_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';
import '../config/api_constants.dart';
import 'edu_screen.dart';
import 'exam_extract_screen.dart';
import 'login_screen.dart';
import 'my_content_screen.dart';
import 'admin_panel_screen.dart';
import 'super_admin_screen.dart';
import 'admin_members_screen.dart';
import 'user_replies_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  int _unreadReplyCount = 0;
  bool _swipeFeedEnabled = true;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().refreshUser();
      _loadUnreadCount();
      _loadSwipePreference();
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadSwipePreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _swipeFeedEnabled = prefs.getBool('swipe_feed_enabled') ?? true;
      });
    }
  }

  Future<void> _toggleSwipeFeed(bool value) async {
    setState(() => _swipeFeedEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('swipe_feed_enabled', value);
  }

  Future<void> _loadUnreadCount() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return;
    try {
      final resp = await auth.dio.get('/user/notifications/unread_count');
      if (resp.statusCode == 200 && mounted) {
        setState(() {
          _unreadReplyCount = resp.data['count'] ?? 0;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final user = authProvider.user;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 背景
          if (!themeProvider.isBackgroundVisible)
            _buildDefaultBackground(isDark),

          // 内容
          FadeTransition(
            opacity: _fadeAnimation,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: SafeArea(
                    bottom: false,
                    child: _buildHeader(user, authProvider, isDark),
                  ),
                ),

                // 管理入口（仅管理员可见）
                if (user?.isAdmin == true)
                  SliverToBoxAdapter(
                      child: _buildAdminSection(context, user, isDark)),

                // 收到邀请（所有用户）
                if (authProvider.isLoggedIn)
                  SliverToBoxAdapter(
                      child: _buildInvitationSection(
                          context, authProvider, isDark)),

                // 教务版块（绑定状态 + 题库入口）
                SliverToBoxAdapter(
                  child: _buildEduSection(context, isDark),
                ),

                // 我的内容
                SliverToBoxAdapter(
                  child: _buildMyContentSection(context, isDark),
                ),

                // 设置区域
                SliverToBoxAdapter(
                  child: _buildSettingsSection(
                      context, themeProvider, authProvider, isDark),
                ),

                const SliverToBoxAdapter(
                  child: SizedBox(height: 100),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultBackground(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: ResizeImage(
              const AssetImage('assets/images/morenbeijing.jpeg'),
              width: 1080),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF1A1A2E),
                        const Color(0xFF16213E),
                        const Color(0xFF0F3460)
                      ]
                    : [
                        const Color(0xFF667EEA),
                        const Color(0xFF764BA2),
                        const Color(0xFFF093FB)
                      ],
              ),
            ),
          ),
        ),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.25)),
      ],
    );
  }

  Widget _buildHeader(user, AuthProvider authProvider, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // 头像
          GestureDetector(
            onTap: () {
              if (authProvider.isLoggedIn) {
                _showAvatarOptions(context, authProvider);
              } else {
                Navigator.push(
                    context,
                    PageRouteBuilder(
                      opaque: false,
                      pageBuilder: (_, __, ___) => LoginScreen(),
                    ));
              }
            },
            child: GlassContainer(
              padding: const EdgeInsets.all(6),
              borderRadius: 100,
              blur: 20,
              opacity: 0.2,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Theme.of(context).primaryColor,
                      Theme.of(context).primaryColor.withOpacity(0.6),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).primaryColor.withOpacity(0.3),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: user?.avatar.isNotEmpty == true
                    ? ClipOval(
                        child: GestureDetector(
                          onLongPress: user?.avatar.isNotEmpty == true
                              ? () => _showAvatarPreview(
                                  context, ApiConstants.fullUrl(user!.avatar))
                              : null,
                          child: CachedNetworkImage(
                            imageUrl: ApiConstants.fullUrl(user?.avatar ?? ''),
                            fit: BoxFit.cover,
                            placeholder: (_, __) =>
                                _buildAvatarPlaceholder(user),
                            errorWidget: (_, __, ___) =>
                                _buildAvatarPlaceholder(user),
                            memCacheWidth: 256,
                          ),
                        ),
                      )
                    : _buildAvatarPlaceholder(user),
              ),
            ),
          ),

          const SizedBox(height: 20),

          GestureDetector(
            onTap: () {
              if (authProvider.isLoggedIn)
                _showEditProfileDialog(context, authProvider);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  user?.nickname ?? '未登录',
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
                if (authProvider.isLoggedIn) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.edit, size: 16, color: Colors.white54),
                ],
              ],
            ),
          ),

          const SizedBox(height: 8),

          if (user?.eduCollege != null || user?.eduMajor != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${user?.eduCollege ?? ""} ${user?.eduMajor ?? ""}'.trim(),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),

          const SizedBox(height: 20),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStatBadge(
                icon: Icons.verified,
                label: '诚信度',
                value: '${user?.creditScore ?? 100}%',
                color: Colors.green,
              ),
              const SizedBox(width: 12),
              _buildStatBadge(
                icon: Icons.star,
                label: '经验',
                value: '${user?.exp ?? 0}',
                color: Colors.amber,
              ),
              if (user?.isAdmin == true) ...[
                const SizedBox(width: 12),
                _buildStatBadge(
                  icon: Icons.admin_panel_settings,
                  label: user?.isSuperAdmin == true ? '超级管理员' : '管理员',
                  value: '经验 ${user?.adminExp ?? 0}',
                  color: Colors.orange,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarPlaceholder(user) {
    return Center(
      child: Text(
        user?.nickname?.substring(0, 1).toUpperCase() ?? '?',
        style: const TextStyle(
            fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white),
      ),
    );
  }

  Widget _buildStatBadge(
      {required IconData icon,
      required String label,
      required String value,
      required Color color}) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      borderRadius: 25,
      blur: 15,
      opacity: 0.15,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 10, color: Colors.black87)),
              Text(value,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAdminSection(BuildContext context, user, bool isDark) {
    final auth = context.read<AuthProvider>();
    return FutureBuilder<Map<String, int>>(
      future: _loadAdminOverview(auth, user),
      builder: (_, snap) {
        final overview = snap.data ?? const {'admin': 0, 'super': 0};
        final adminTodo = overview['admin'] ?? 0;
        final superTodo = overview['super'] ?? 0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            children: [
              _buildAdminEntry(
                context: context,
                isDark: isDark,
                icon: Icons.admin_panel_settings,
                iconColor: Colors.red,
                title: '管理处',
                subtitle: adminTodo > 0
                    ? '处理举报、审核教师和专业 · $adminTodo 条待办'
                    : '处理举报、审核教师和专业',
                badgeText: adminTodo > 0 ? '$adminTodo' : null,
                onTap: () {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminPanelScreen()));
                },
              ),
              if (user?.isSuperAdmin == true) ...[
                const SizedBox(height: 12),
                _buildAdminEntry(
                  context: context,
                  isDark: isDark,
                  icon: Icons.security,
                  iconColor: Colors.deepPurple,
                  title: '超级管理员',
                  subtitle: superTodo > 0
                      ? '管理用户、审批管理员邀请 · $superTodo 条待办'
                      : '管理用户、审批管理员邀请',
                  badgeText: superTodo > 0 ? '$superTodo' : null,
                  onTap: () {
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SuperAdminScreen()));
                  },
                ),
              ],
              const SizedBox(height: 12),
              _buildAdminEntry(
                context: context,
                isDark: isDark,
                icon: Icons.groups_2_outlined,
                iconColor: Colors.indigo,
                title: '管理人员',
                subtitle: '查看管理员与超级管理员列表',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminMembersScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAdminEntry({
    required BuildContext context,
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    String? badgeText,
    required VoidCallback onTap,
  }) {
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      blur: 10,
      opacity: 0.15,
      gradientColors: isDark
          ? [Colors.red[800]!, Colors.red[900]!]
          : [Colors.red[50]!, Colors.red[100]!],
      onTap: onTap,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : Colors.grey[600]),
                ),
              ],
            ),
          ),
          if (badgeText != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeText,
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }

  Future<Map<String, int>> _loadAdminOverview(
      AuthProvider auth, dynamic user) async {
    Future<List<dynamic>> loadList(String path) async {
      try {
        final response = await auth.dio.get(path);
        return (response.data as List?) ?? [];
      } catch (_) {
        return const [];
      }
    }

    final pendingTeachers = await loadList('/teachers/pending');
    final pendingMajors = await loadList('/majors/pending');
    final pendingInvitations = await loadList('/admin/invitations/pending');
    final pendingRemovals = await loadList('/admin/removals/pending');

    final adminCount = pendingTeachers.length +
        pendingMajors.length +
        pendingInvitations.where((i) => i['my_vote'] != true).length +
        pendingRemovals.where((r) => r['can_vote'] == true).length;

    var superCount = 0;
    if (user?.isSuperAdmin == true) {
      final superInvitations = await loadList('/super/invitations/pending');
      superCount = superInvitations.where((i) => i['my_vote'] != true).length;
    }

    return {'admin': adminCount, 'super': superCount};
  }

  Widget _buildMyContentSection(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '我的内容',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
          ),
          _buildSettingsCard(
            isDark,
            children: [
              _buildSettingsTile(
                icon: Icons.article_outlined,
                iconColor: const Color(0xFF6366F1),
                title: '我的内容',
                subtitle: '管理发布的帖子与集市物品',
                isDark: isDark,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MyContentScreen()),
                  );
                },
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.notifications_active_outlined,
                iconColor: Colors.orange,
                title: '收到的回复',
                subtitle: _unreadReplyCount > 0 ? '$_unreadReplyCount条新回复' : null,
                trailing: _unreadReplyCount > 0
                    ? Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      )
                    : null,
                isDark: isDark,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UserRepliesScreen()),
                  ).then((_) {
                    _loadUnreadCount();
                  });
                },
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.bug_report_outlined,
                iconColor: Colors.green,
                title: '功能建议 (Bug提交)',
                subtitle: '提交的建议会发送至开发者邮箱',
                isDark: isDark,
                onTap: () => _showFeedbackDialog(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildEduSection(BuildContext context, bool isDark) {
    final eduProvider = context.watch<EduProvider>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '教务',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
          ),
          _buildSettingsCard(
            isDark,
            children: [
              // 绑定状态
              _buildSettingsTile(
                icon: Icons.school,
                iconColor: eduProvider.isBound ? Colors.green : Colors.grey,
                title: '教务',
                subtitle: eduProvider.isBound
                    ? '${eduProvider.studentId} | ${eduProvider.college}'
                    : '绑定后可查询课表、成绩',
                isDark: isDark,
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const EduScreen())),
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              // 题库入口
              _buildSettingsTile(
                icon: Icons.auto_stories,
                iconColor: const Color(0xFF667EEA),
                title: '导入融智云考题库',
                subtitle: '提取练习题，导出 Markdown',
                isDark: isDark,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ExamExtractScreen()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildSettingsSection(BuildContext context,
      ThemeProvider themeProvider, AuthProvider authProvider, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 背景设置
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildSettingsCard(
            isDark,
            children: [
              _buildSettingsTile(
                icon: Icons.wallpaper,
                iconColor: Colors.purple,
                title: '自定义背景',
                isDark: isDark,
                onTap: () => _showBackgroundPicker(context, themeProvider),
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.opacity,
                iconColor: Colors.teal,
                title: '组件透明度',
                trailing: SizedBox(
                  width: 150,
                  child: Slider(
                    value: themeProvider.componentOpacity,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) => themeProvider.setComponentOpacity(v),
                    activeColor: Theme.of(context).primaryColor,
                  ),
                ),
                isDark: isDark,
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.restore,
                iconColor: Colors.orange,
                title: '默认壁纸',
                subtitle: '恢复为系统默认背景',
                isDark: isDark,
                onTap: () => _showRestoreDefaultDialog(context, themeProvider),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 视觉效果
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildSettingsCard(
            isDark,
            children: [
              _buildSettingsTile(
                icon: Icons.blur_on,
                iconColor: Colors.indigo,
                title: '液态玻璃效果',
                trailing: Switch(
                  value: themeProvider.liquidGlass,
                  onChanged: (v) =>
                      _showLiquidGlassWarningDialog(context, themeProvider, v),
                  activeColor: Theme.of(context).primaryColor,
                ),
                isDark: isDark,
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.navigation,
                iconColor: Colors.orange,
                title: '悬浮底栏',
                trailing: Switch(
                  value: themeProvider.floatingNavBar,
                  onChanged: (v) => themeProvider.setFloatingNavBar(v),
                  activeColor: Theme.of(context).primaryColor,
                ),
                isDark: isDark,
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.swipe,
                iconColor: Colors.blue,
                title: '左右滑动切版块',
                subtitle: '首页左滑切换到热门/最新，关闭后仅手动点击切换',
                trailing: Switch(
                  value: _swipeFeedEnabled,
                  onChanged: _toggleSwipeFeed,
                  activeColor: Theme.of(context).primaryColor,
                ),
                isDark: isDark,
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.dark_mode,
                iconColor: isDark ? Colors.indigo : Colors.indigo,
                title: '夜间模式',
                trailing: Switch(
                  value: themeProvider.isDarkMode,
                  onChanged: (v) => themeProvider.setDarkMode(v),
                  activeColor: Theme.of(context).primaryColor,
                ),
                isDark: isDark,
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 账号
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildSettingsCard(
            isDark,
            children: [
              _buildSettingsTile(
                icon: Icons.person,
                iconColor: Colors.blue,
                title: '编辑资料',
                isDark: isDark,
                onTap: () => _showEditProfileDialog(context, authProvider),
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.lock,
                iconColor: Colors.orange,
                title: '修改密码',
                isDark: isDark,
                onTap: () => _showChangePasswordDialog(context, authProvider),
              ),
              Divider(
                  height: 1,
                  indent: 68,
                  color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.info,
                iconColor: Colors.blue,
                title: '关于',
                isDark: isDark,
                onTap: () => _showAboutDialog(context),
              ),
            ],
          ),
        ),

        // 退出登录
        if (authProvider.isLoggedIn) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _checkUpdate(context),
                icon: const Icon(Icons.system_update, size: 18),
                label: const Text('检查更新'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? Colors.white70 : Colors.grey[700],
                  side: BorderSide(
                      color: isDark ? Colors.white24 : Colors.grey[300]!),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: GradientButton(
              text: '退出登录',
              gradientColors: [Colors.red[400]!, Colors.red[600]!],
              onPressed: () async {
                await authProvider.logout();
                if (context.mounted) {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                }
              },
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _checkUpdate(BuildContext context) async {
    const giteeUrl = 'https://gitee.com/chunhezi/SYLUlive/releases';
    const githubUrl = 'https://github.com/zhouwu97/SYLUlive/releases';
    try {
      final dio = context.read<AuthProvider>().dio;
      final packageInfo = await PackageInfo.fromPlatform();
      final resp = await dio.get('/version');
      if (resp.statusCode == 200) {
        final data = resp.data is Map ? resp.data as Map : <String, dynamic>{};
        final latestVersion = data['version']?.toString() ?? '';
        final forceUpdate = data['force_update'] ?? false;
        final giteeDownloadUrl =
            data['gitee_download_url']?.toString().trim().isNotEmpty == true
                ? data['gitee_download_url'].toString()
                : giteeUrl;
        final githubDownloadUrl =
            data['github_download_url']?.toString().trim().isNotEmpty == true
                ? data['github_download_url'].toString()
                : (data['download_url']?.toString().trim().isNotEmpty == true
                    ? data['download_url'].toString()
                    : githubUrl);
        final updateMsg = data['update_msg'] ?? '新版本可用';
        final currentVersion = packageInfo.version;
        final hasUpdate =
            forceUpdate || _isRemoteVersionNewer(latestVersion, currentVersion);

        if (!context.mounted) return;
        showDialog(
          context: context,
          barrierDismissible: !forceUpdate,
          builder: (ctx) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(children: [
              Icon(
                hasUpdate ? Icons.system_update : Icons.verified_outlined,
                color: hasUpdate ? Colors.blue : Colors.green,
              ),
              const SizedBox(width: 8),
              Text(hasUpdate ? '发现新版本' : '已是最新版'),
            ]),
            content: Text(
              hasUpdate
                  ? '当前版本: $currentVersion\n最新版本: $latestVersion\n$updateMsg\n\n请选择下载来源。'
                  : '当前版本: $currentVersion\n服务器版本: ${latestVersion.isEmpty ? '未知' : latestVersion}\n当前已是最新版本。',
              style: const TextStyle(height: 1.5),
            ),
            actions: [
              if (!hasUpdate || !forceUpdate)
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(hasUpdate ? '稍后' : '关闭')),
              if (hasUpdate)
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    launchUrl(Uri.parse(giteeDownloadUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('Gitee下载'),
                ),
              if (hasUpdate)
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    launchUrl(Uri.parse(githubDownloadUrl),
                        mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('GitHub下载'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white),
                ),
            ],
          ),
        );
      }
    } on DioException catch (e) {
      if (context.mounted) {
        AppFeedback.showSnackBar(
          context,
          AppFeedback.dioErrorMessage(e, fallback: '检查更新失败'),
          isError: true,
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppFeedback.showSnackBar(context, '检查更新失败: $e', isError: true);
      }
    }
  }

  bool _isRemoteVersionNewer(String remote, String current) {
    final remoteParts = _parseVersion(remote);
    final currentParts = _parseVersion(current);
    final maxLength = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var i = 0; i < maxLength; i++) {
      final r = i < remoteParts.length ? remoteParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (r > c) return true;
      if (r < c) return false;
    }
    return false;
  }

  List<int> _parseVersion(String version) {
    final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    return normalized
        .split(RegExp(r'[.+-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
  }

  Widget _buildSettingsCard(bool isDark, {required List<Widget> children}) {
    return GlassContainer(
      padding: EdgeInsets.zero,
      borderRadius: 16,
      blur: 10,
      opacity: 0.15,
      child: Column(children: children),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    required bool isDark,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              if (subtitle != null)
                Text(subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: isDark ? Colors.white60 : Colors.grey[600],
                        fontSize: 13)),
              if (trailing != null) trailing,
              if (trailing == null && onTap != null)
                Icon(Icons.chevron_right,
                    color: isDark ? Colors.white30 : Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  void _showBackgroundPicker(
      BuildContext context, ThemeProvider themeProvider) {
    final backgrounds = [
      'bg-mobile.png',
      'https://images.unsplash.com/photo-1579546929518-9e396f3cc809?w=800',
      'https://images.unsplash.com/photo-1557682250-33bd709cbe85?w=800',
      'https://images.unsplash.com/photo-1519681393784-d120267933ba?w=800',
      'https://images.unsplash.com/photo-1507400492013-162706c8c05e?w=800',
      'https://images.unsplash.com/photo-1518837695005-2083093ee35b?w=800',
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择背景',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 120,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: backgrounds.length,
                      itemBuilder: (context, index) {
                        final isAsset = !backgrounds[index].startsWith('http');
                        final imagePath = isAsset
                            ? 'assets/images/${backgrounds[index]}'
                            : backgrounds[index];
                        return GestureDetector(
                          onTap: () {
                            themeProvider
                                .setBackgroundImage(backgrounds[index]);
                            Navigator.pop(context);
                          },
                          child: Container(
                            width: 160,
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              image: DecorationImage(
                                image: isAsset
                                    ? AssetImage(imagePath) as ImageProvider
                                    : NetworkImage(backgrounds[index])
                                        as ImageProvider,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final picker = ImagePicker();
                  final image =
                      await picker.pickImage(source: ImageSource.gallery);
                  if (image != null) {
                    final appDir = await getApplicationDocumentsDirectory();
                    final fileName =
                        'background_${DateTime.now().millisecondsSinceEpoch}${path.extension(image.path)}';
                    final savedPath = path.join(appDir.path, fileName);
                    await File(image.path).copy(savedPath);
                    themeProvider.setBackgroundImage(savedPath);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.photo_library),
                label: const Text('从相册选择'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _showRestoreDefaultDialog(
      BuildContext context, ThemeProvider themeProvider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('恢复默认壁纸'),
        content: const Text('将清除当前自定义背景，所有页面恢复为系统默认壁纸。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              themeProvider.clearBackground();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('已恢复默认壁纸'), backgroundColor: Colors.green),
              );
            },
            child: const Text('确认恢复', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showLiquidGlassWarningDialog(
      BuildContext context, ThemeProvider themeProvider, bool enable) {
    if (!enable) {
      themeProvider.setLiquidGlass(false);
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded,
              color: Colors.orange.shade400, size: 28),
          const SizedBox(width: 12),
          const Text('性能警告'),
        ]),
        content: const Text('液态玻璃效果基于模糊算法实现，在部分设备上可能会造成卡顿。',
            style: TextStyle(height: 1.5)),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
              },
              child: const Text('了解，但继续开启')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              themeProvider.setLiquidGlass(true);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('开启'),
          ),
        ],
      ),
    );
  }

  void _showAvatarPreview(BuildContext context, String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
              child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)),
        ),
      ),
    );
  }

  void _showEditProfileDialog(BuildContext context, AuthProvider authProvider) {
    final controller = TextEditingController(text: authProvider.user?.nickname);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑资料'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '昵称')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              final result = await authProvider.updateProfile(controller.text);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.success
                      ? '更新成功'
                      : (result.errorMessage ?? '更新失败')),
                  backgroundColor: result.success ? Colors.green : Colors.red,
                ));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog(
      BuildContext context, AuthProvider authProvider) {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: oldController,
              decoration: const InputDecoration(labelText: '旧密码'),
              obscureText: true),
          const SizedBox(height: 16),
          TextField(
              controller: newController,
              decoration: const InputDecoration(labelText: '新密码'),
              obscureText: true),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              final result = await authProvider.changePassword(
                  oldController.text, newController.text);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.success
                      ? '修改成功'
                      : (result.errorMessage ?? '修改失败')),
                  backgroundColor: result.success ? Colors.green : Colors.red,
                ));
              }
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _showAvatarOptions(BuildContext context, AuthProvider authProvider) {
    Future<void> pickAndUpload(ImageSource source) async {
      Navigator.pop(context);
      final image = await ImagePicker().pickImage(source: source);
      if (image == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final fileName =
          'avatar_${DateTime.now().millisecondsSinceEpoch}${path.extension(image.path)}';
      final savedPath = path.join(appDir.path, fileName);
      await File(image.path).copy(savedPath);
      final result = await authProvider.updateAvatar(savedPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              result.success ? '头像更新成功' : (result.errorMessage ?? '头像更新失败')),
          backgroundColor: result.success ? Colors.green : Colors.red,
        ));
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo),
            title: const Text('从相册选择'),
            onTap: () => pickAndUpload(ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('拍照'),
            onTap: () => pickAndUpload(ImageSource.camera),
          ),
        ]),
      ),
    );
  }

  void _showAvatarViewer(BuildContext context, String avatarUrl) {
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.transparent),
            body: Center(
                child: InteractiveViewer(child: Image.network(avatarUrl))),
          ),
        ));
  }

  void _showAboutDialog(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.65,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1A2E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            // 顶部拖拽条
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    // App 图标 - 渐变圆角
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [primary, primary.withOpacity(0.6)],
                        ),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: primary.withOpacity(0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.school, color: Colors.white, size: 42),
                    ),
                    const SizedBox(height: 20),
                    // 标题
                    Text(
                      '沈理校园',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '校园互助社交应用',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white54 : Colors.grey[500],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'v1.0.0',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // 信息卡片
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.05)
                            : Colors.grey.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark ? Colors.white10 : Colors.grey.withOpacity(0.12),
                        ),
                      ),
                      child: Column(children: [
                        _buildAboutInfoRow(
                          Icons.person_outline_rounded,
                          '开发者',
                          '纯合子',
                          isDark,
                        ),
                        Divider(height: 20, color: isDark ? Colors.white10 : Colors.grey[200]),
                        _buildAboutInfoRow(
                          Icons.school_outlined,
                          '面向',
                          '沈阳理工大学全体师生',
                          isDark,
                        ),
                        Divider(height: 20, color: isDark ? Colors.white10 : Colors.grey[200]),
                        _buildAboutInfoRow(
                          Icons.favorite_outline_rounded,
                          '理念',
                          '让校园生活更简单',
                          isDark,
                        ),
                      ]),
                    ),
                    const SizedBox(height: 20),

                    // 联系方式标题
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '联系与反馈',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white54 : Colors.grey[600],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // 联系按钮组
                    Row(
                      children: [
                        Expanded(
                          child: _buildAboutContactCard(
                            context,
                            icon: Icons.code_rounded,
                            label: 'GitHub',
                            subtitle: '开源仓库',
                            gradient: [const Color(0xFF24292E), const Color(0xFF404448)],
                            onTap: () => _launchUrl('https://github.com/zhouwu97/SYLUlive'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildAboutContactCard(
                            context,
                            icon: Icons.email_rounded,
                            label: '邮箱',
                            subtitle: '复制地址',
                            gradient: [const Color(0xFFEA4335), const Color(0xFFFF6B6B)],
                            onTap: () => _copyToClipboard(context, '3170305904@qq.com', '邮箱地址已复制'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildAboutContactCard(
                            context,
                            icon: Icons.chat_rounded,
                            label: 'QQ',
                            subtitle: '直接联系',
                            gradient: [const Color(0xFF12B7F5), const Color(0xFF5DC4F8)],
                            onTap: () => _launchUrl(
                                'mqqapi://card/show_pslcard?src_type=internal&version=1&uin=3170305904&card_type=person'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutInfoRow(IconData icon, String label, String value, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 20, color: isDark ? Colors.white38 : Colors.grey[500]),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white38 : Colors.grey[500],
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
      ],
    );
  }

  Widget _buildAboutContactCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required List<Color> gradient,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: gradient.first.withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(
      BuildContext context, String text, String successMessage) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(successMessage),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      debugPrint('Could not launch URL: $url');
    }
  }

  // ---- 邀请版块 ----
  Widget _buildInvitationSection(
      BuildContext context, AuthProvider auth, bool isDark) {
    return FutureBuilder(
      future: auth.dio.get('/user/invitations'),
      builder: (_, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final list = (snap.data!.data as List?) ?? [];
        if (list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildSettingsCard(isDark, children: [
            Padding(
                padding: const EdgeInsets.all(16),
                child: Text('收到管理员邀请',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87))),
            ...list.map((inv) => ListTile(
                  leading: const Icon(Icons.person_add, color: Colors.blue),
                  title: Text('${inv['inviter']?['nickname'] ?? ''} 邀请你成为管理员'),
                  subtitle: Text(
                      '理由：${inv['reason'] ?? '未填写'}\n${(inv['inviter']?['role'] == 'super_admin') ? '同意后将直接成为管理员' : '同意后会进入管理员代办，满 3 票后生效'}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        icon:
                            const Icon(Icons.check_circle, color: Colors.green),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final res = await auth.dio
                              .post('/user/invitations/${inv['id']}/accept');
                          if (res.data is Map &&
                              res.data['token'] is String &&
                              res.data['user'] is Map<String, dynamic>) {
                            await auth.applyAuthPayload(
                              res.data['token'] as String,
                              res.data['user'] as Map<String, dynamic>,
                            );
                          }
                          final message =
                              (res.data is Map && res.data['message'] != null)
                                  ? res.data['message'].toString()
                                  : '已接受邀请';
                          if (mounted) {
                            messenger.showSnackBar(SnackBar(
                                content: Text(message),
                                backgroundColor: Colors.green));
                            auth.refreshUser();
                            setState(() {});
                          }
                        }),
                    IconButton(
                        icon: const Icon(Icons.cancel, color: Colors.red),
                        onPressed: () async {
                          await auth.dio
                              .post('/user/invitations/${inv['id']}/reject');
                          if (mounted) {
                            auth.refreshUser();
                            setState(() {});
                          }
                        }),
                  ]),
                )),
          ]),
        );
      },
    );
  }
  void _showFeedbackDialog(BuildContext context) {
    final controller = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('功能建议与 Bug 提交'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: '请输入您的建议或遇到的问题...\n提交后会发送至开发者邮箱。',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final text = controller.text.trim();
                      if (text.isEmpty) {
                        AppFeedback.showSnackBar(context, '内容不能为空');
                        return;
                      }
                      setDialogState(() => isSubmitting = true);
                      try {
                        final auth = context.read<AuthProvider>();
                        // 触发后端接口，后端会将邮件发送至 13514252317@163.com
                        final response = await auth.dio.post('/feedback', data: {'content': text});
                        if (response.statusCode == 200 || response.statusCode == 201) {
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            AppFeedback.showSnackBar(context, '反馈已提交，感谢您的建议！');
                          }
                        } else {
                          if (ctx.mounted) {
                            AppFeedback.showSnackBar(context, '提交失败，请稍后重试', isError: true);
                            setDialogState(() => isSubmitting = false);
                          }
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          AppFeedback.showSnackBar(context, '网络异常或接口未部署，反馈提交失败', isError: true);
                          setDialogState(() => isSubmitting = false);
                        }
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('提交'),
            ),
          ],
        ),
      ),
    );
  }
}
