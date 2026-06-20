import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../providers/message_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/update_checker.dart';
import '../utils/responsive_util.dart';
import '../widgets/glass_container.dart';
import '../widgets/cached_avatar.dart';
import '../config/api_constants.dart';
import '../config/privileged_accounts.dart';
import 'edu_screen.dart';
import 'exam_extract_screen.dart';
import 'login_screen.dart';
import 'my_content_screen.dart';
import 'chat_list_screen.dart';
import 'admin_panel_screen.dart';
import 'super_admin_screen.dart';
import 'admin_members_screen.dart';
import 'oneclass_orders_screen.dart';
import 'user_replies_screen.dart';
import 'settings_screen.dart';
import 'feedback_screen.dart';
import 'user_home_screen.dart';
import 'social_list_screen.dart';

class ProfileScreen extends StatefulWidget {
  final bool isActive;

  const ProfileScreen({
    super.key,
    this.isActive = true,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  int _unreadReplyCount = 0;
  int _unreadMessageCount = 0;
  bool _startOnTimetable = false;
  int? _postCount;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 1, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().refreshUser();
      _loadUnreadCount();
      _loadPrefs();
      _fetchPostCount();
    });
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _loadUnreadCount();
      _fetchPostCount();
    }
  }

  Future<void> _fetchPostCount() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn || auth.user == null) return;

    // 如果有缓存，直接使用缓存秒开
    if (MyContentScreen.globalPostCount != null) {
      if (mounted) {
        setState(() {
          _postCount = MyContentScreen.globalPostCount;
        });
      }
      // 不直接 return，在后台静默刷新以保证数据一致性
    }

    try {
      final res = await auth.dio.get('/user/${auth.user!.id}/posts/count');
      if (res.statusCode == 200 && mounted) {
        setState(() {
          _postCount = res.data['count'] ?? 0;
          MyContentScreen.globalPostCount = _postCount; // 同步更新缓存
        });
      }
    } catch (e) {
      debugPrint('刷新我的内容数量失败: $e');
    }
  }

  void _loadPrefs() {
    final tp = context.read<ThemeProvider>();
    if (mounted) setState(() => _startOnTimetable = tp.startOnTimetable);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadUnreadCount() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return;
    try {
      final repliesFuture = auth.dio.get('/user/notifications/unread_count');
      final messagesFuture = auth.dio.get('/messages/unread_count');
      final responses = await Future.wait([repliesFuture, messagesFuture]);
      if (mounted) {
        final replyResp = responses[0];
        final messageResp = responses[1];
        if (replyResp.statusCode == 200 && messageResp.statusCode == 200) {
          setState(() {
            _unreadReplyCount = replyResp.data['count'] ?? 0;
            _unreadMessageCount = messageResp.data['count'] ?? 0;
          });
        }
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
          // 内容
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      _buildHeader(user, authProvider, isDark),
                      if (authProvider.isLoggedIn)
                        _buildSocialStatsSection(context, user, isDark),
                    ],
                  ),
                ),
              ),

              // 管理入口（仅管理员可见）
              if (user?.isAdmin == true)
                SliverToBoxAdapter(
                    child: _buildAdminSection(context, user, isDark)),

              // 收到邀请（所有用户）
              if (authProvider.isLoggedIn)
                SliverToBoxAdapter(
                    child:
                        _buildInvitationSection(context, authProvider, isDark)),

              // 教务版块（绑定状态 + 题库入口）
              SliverToBoxAdapter(
                child: _buildEduSection(context, authProvider, isDark),
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

              SliverToBoxAdapter(
                child: SizedBox(
                    height: MediaQuery.of(context).padding.bottom + 90),
              ),
            ],
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧：头像
          GestureDetector(
            onTap: () {
              if (authProvider.isLoggedIn) {
                _showAvatarOptions(context, authProvider);
              } else {
                Navigator.push(
                    context,
                    PageRouteBuilder(
                      opaque: false,
                      pageBuilder: (_, __, ___) => const LoginScreen(),
                    ));
              }
            },
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    spreadRadius: 2,
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
                        child: CachedAvatar(
                          imageUrl: ApiConstants.fullUrl(user?.avatar ?? ''),
                          radius: 36,
                          fallbackText: user?.nickname,
                        ),
                      ),
                    )
                  : _buildAvatarPlaceholder(user),
            ),
          ),

          const SizedBox(width: 16),

          // 右侧：信息与箭头 (整个区域可点击进入主页)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (authProvider.isLoggedIn) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UserHomeScreen()),
                  );
                } else {
                  Navigator.push(
                    context,
                    PageRouteBuilder(
                      opaque: false,
                      pageBuilder: (_, __, ___) => const LoginScreen(),
                    ),
                  );
                }
              },
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 第一行：昵称与编辑按钮
                        GestureDetector(
                          onTap: () {
                            if (authProvider.isLoggedIn) {
                              _showEditProfileDialog(context, authProvider);
                            }
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  user?.nickname ?? '未登录',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color:
                                        isDark ? Colors.white : Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (authProvider.isLoggedIn) ...[
                                const SizedBox(width: 6),
                                Icon(Icons.edit,
                                    size: 16,
                                    color: isDark
                                        ? Colors.white54
                                        : Colors.black54),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 8),

                        // 第二行：学院专业标签 (如果有)
                        if (user?.eduCollege != null &&
                            user!.eduCollege!.isNotEmpty) ...[
                          Text(
                            '${user.eduCollege} ${user.eduMajor}'.trim(),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                        ],

                        // 第三行：数据统计 (等级、诚信、经验等)
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (user != null)
                              _buildTag(
                                  user.levelLabel.startsWith('Lv')
                                      ? user.levelLabel
                                      : 'Lv.${user.levelLabel}',
                                  icon: Icons.military_tech,
                                  color: Color(user.levelColorValue),
                                  isDark: isDark),
                            _buildTag('诚信 ${user?.creditScore ?? 100}%',
                                icon: Icons.verified_user,
                                color: Colors.teal,
                                isDark: isDark),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 最右侧箭头
                  if (authProvider.isLoggedIn)
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0, right: 4.0),
                      child: Icon(Icons.arrow_forward_ios,
                          size: 14,
                          color: isDark ? Colors.white54 : Colors.black45),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text,
      {IconData? icon, required Color color, required bool isDark}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.2 : 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildSocialStatsSection(BuildContext context, user, bool isDark) {
    if (user == null) return const SizedBox();
    return Container(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 24),
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1E1E1E).withOpacity(0.6)
            : Colors.white.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10.0,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildSocialStatItem(_postCount?.toString() ?? '-', '我的内容', isDark,
              () async {
            await Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MyContentScreen()));
            if (mounted) {
              await _fetchPostCount();
            }
          }),
          _buildSocialStatItem(user.followingCount.toString(), '关注的人', isDark,
              () {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        SocialListScreen(userId: user.id, initialIndex: 0)));
          }),
          _buildSocialStatItem(user.followersCount.toString(), '关注我的', isDark,
              () {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        SocialListScreen(userId: user.id, initialIndex: 1)));
          }),
        ],
      ),
    );
  }

  Widget _buildSocialStatItem(
      String count, String label, bool isDark, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            count,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
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
        final items = [
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
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
            },
          ),
          if (user?.isSuperAdmin == true)
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
          if (PrivilegedAccounts.canViewOneClassOrders(user?.studentId))
            _buildAdminEntry(
              context: context,
              isDark: isDark,
              icon: Icons.receipt_long,
              iconColor: Colors.teal,
              title: 'OneClass 订单',
              subtitle: '查看 OneClass 支付、机器授权与签发状态',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const OneClassOrdersScreen(),
                  ),
                );
              },
            ),
        ];

        return _buildSectionLayout(context, '管理员', items, isDark);
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
      padding: const EdgeInsets.all(12),
      borderRadius: 16,
      blur: 10,
      opacity: 0.15,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                      fontSize: 12,
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

  Widget _buildSectionLayout(
      BuildContext context, String title, List<Widget> items, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
          ),
          if (ResponsiveUtil.isDesktop(context))
            LayoutBuilder(builder: (context, constraints) {
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: items
                    .map((e) => SizedBox(
                          width: (constraints.maxWidth - 12) / 2,
                          child: e,
                        ))
                    .toList(),
              );
            })
          else
            Column(
              children: [
                for (int i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  items[i],
                ],
              ],
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildMyContentSection(BuildContext context, bool isDark) {
    final totalUnreadCount = _unreadReplyCount + _unreadMessageCount;
    final items = [
      _buildSettingsRow(
          child: _buildSettingsTile(
        icon: Icons.chat_outlined,
        iconColor: const Color(0xFF10B981),
        title: '私信',
        subtitle: totalUnreadCount > 0
            ? '共$totalUnreadCount条未读，含$_unreadMessageCount条私信'
            : '查看私信与系统通知',
        trailing: totalUnreadCount > 0
            ? Container(
                width: 8,
                height: 8,
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
            MaterialPageRoute(builder: (_) => const ChatListScreen()),
          ).then((_) {
            _loadUnreadCount();
          });
        },
      )),
      _buildSettingsRow(
          child: _buildSettingsTile(
        icon: Icons.notifications_active_outlined,
        iconColor: Colors.orange,
        title: '收到的回复',
        subtitle: _unreadReplyCount > 0 ? '$_unreadReplyCount条新回复' : null,
        trailing: _unreadReplyCount > 0
            ? Container(
                width: 8,
                height: 8,
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
      )),
      _buildSettingsRow(
          child: _buildSettingsTile(
        icon: Icons.bug_report_outlined,
        iconColor: Colors.green,
        title: '功能建议 (Bug提交)',
        subtitle: '提交的建议会发送至开发者邮箱',
        isDark: isDark,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const FeedbackScreen()),
        ),
      )),
    ];
    return _buildSectionLayout(context, '我的内容', items, isDark);
  }

  Widget _buildEduSection(
      BuildContext context, AuthProvider authProvider, bool isDark) {
    final eduProvider = context.watch<EduProvider>();
    final items = [
      _buildSettingsRow(
          child: _buildSettingsTile(
        icon: Icons.school,
        iconColor: eduProvider.isBound ? Colors.green : Colors.grey,
        title: '教务',
        subtitle: eduProvider.isBound
            ? '${eduProvider.studentId} | ${eduProvider.college}'
            : '绑定后可查询课表、成绩',
        isDark: isDark,
        onTap: () {
          Navigator.push(
              context, MaterialPageRoute(builder: (_) => const EduScreen()));
        },
      )),
      _buildSettingsRow(
        child: _buildSettingsTile(
          icon: _startOnTimetable ? Icons.calendar_today : Icons.home_rounded,
          iconColor: const Color(0xFF667EEA),
          title: '下次直接进入课表',
          subtitle: _startOnTimetable ? '已开启' : '已关闭',
          isDark: isDark,
          trailing: Switch(
            value: _startOnTimetable,
            activeColor: const Color(0xFF6366F1),
            onChanged: (v) {
              context.read<ThemeProvider>().setStartOnTimetable(v);
              if (mounted) setState(() => _startOnTimetable = v);
            },
          ),
        ),
      ),
      _buildSettingsRow(
          child: _buildSettingsTile(
        icon: Icons.auto_stories,
        iconColor: const Color(0xFF667EEA),
        title: '导入融智云考题库',
        subtitle: '提取练习题，导出 Markdown',
        isDark: isDark,
        onTap: () {
          if (!authProvider.isLoggedIn) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('请先登录')));
            return;
          }
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ExamExtractScreen()),
          );
        },
      )),
    ];
    return _buildSectionLayout(context, '教务', items, isDark);
  }

  Widget _buildSettingsSection(BuildContext context,
      ThemeProvider themeProvider, AuthProvider authProvider, bool isDark) {
    final items = [
      _buildSettingsRow(
        child: _buildSettingsTile(
          icon: Icons.settings,
          iconColor: Colors.blueGrey,
          title: '设置',
          subtitle: '主题外观、关于应用、账号设置等',
          isDark: isDark,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SettingsScreen(),
              ),
            );
          },
        ),
      ),
    ];
    return _buildSectionLayout(context, '设置', items, isDark);
  }

  // removed update checker methods

  Widget _buildSettingsCard(bool isDark, {required List<Widget> children}) {
    return GlassContainer(
      padding: EdgeInsets.zero,
      borderRadius: 12,
      blur: 12,
      opacity: 0.15,
      child: Column(children: children),
    );
  }

  /// 独立的设置卡片行（每个设置项单独一张毛玻璃卡片）
  Widget _buildSettingsRow({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: GlassContainer(
        padding: EdgeInsets.zero,
        borderRadius: 12,
        blur: 12,
        opacity: 0.15,
        child: child,
      ),
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
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.grey[600],
                              fontSize: 11)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing,
              if (trailing == null && onTap != null)
                Icon(Icons.chevron_right,
                    size: 18,
                    color: isDark ? Colors.white30 : Colors.grey[400]),
            ],
          ),
        ),
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

  Future<void> _showEditProfileDialog(
      BuildContext context, AuthProvider authProvider) async {
    final controller = TextEditingController(text: authProvider.user?.nickname);
    await showDialog(
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
    controller.dispose();
  }

  void _showAvatarOptions(BuildContext context, AuthProvider authProvider) {
    Future<void> pickAndUpload(ImageSource source) async {
      Navigator.pop(context);
      final image = await ImagePicker().pickImage(source: source);
      if (image == null) return;

      final cropped = await ImageCropper().cropImage(
        sourcePath: image.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '裁剪头像',
            toolbarColor: Colors.black,
            toolbarWidgetColor: Colors.white,
            statusBarColor: Colors.black,
            backgroundColor: Colors.black,
            initAspectRatio: CropAspectRatioPreset.square,
            lockAspectRatio: true,
          ),
          IOSUiSettings(
            title: '裁剪头像',
            aspectRatioLockEnabled: true,
            resetButtonHidden: true,
          ),
        ],
      );

      if (cropped == null) return;

      final avatarBytes = await cropped.readAsBytes();
      if (avatarBytes.length > 10 * 1024 * 1024) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('头像大小不能超过 10MB'), backgroundColor: Colors.red),
          );
        }
        return;
      }

      final result = await authProvider.updateAvatar(avatarBytes);
      if (context.mounted) {
        if (result.success) {
          // 刷新聊天列表中的头像缓存
          context.read<MessageProvider>().loadConversations(silent: true);
        }
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
}
