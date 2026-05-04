import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/edu_provider.dart';
import '../widgets/glass_container.dart';
import '../config/api_constants.dart';
import 'edu_screen.dart';
import 'exam_extract_screen.dart';
import 'login_screen.dart';
import 'my_content_screen.dart';
import 'admin_panel_screen.dart';
import 'exam_extract_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

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
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
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
                    child: _buildAdminSection(context, isDark),
                  ),

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
                  child: _buildSettingsSection(context, themeProvider, authProvider, isDark),
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
          image: ResizeImage(const AssetImage('assets/images/morenbeijing.jpeg'), width: 1080),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [const Color(0xFF1A1A2E), const Color(0xFF16213E), const Color(0xFF0F3460)]
                    : [const Color(0xFF667EEA), const Color(0xFF764BA2), const Color(0xFFF093FB)],
              ),
            ),
          ),
        ),
        Container(color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.25)),
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
                Navigator.push(context, PageRouteBuilder(
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
                          onLongPress: () => _showAvatarPreview(context, ApiConstants.fullUrl(user!.avatar)),
                          child: CachedNetworkImage(
                            imageUrl: ApiConstants.fullUrl(user!.avatar),
                            fit: BoxFit.cover,
                            placeholder: (_, __) => _buildAvatarPlaceholder(user),
                            errorWidget: (_, __, ___) => _buildAvatarPlaceholder(user),
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
              if (authProvider.isLoggedIn) _showEditProfileDialog(context, authProvider);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  user?.nickname ?? '未登录',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
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
              if (user?.isAdmin == true) ...[
                const SizedBox(width: 12),
                _buildStatBadge(
                  icon: Icons.admin_panel_settings,
                  label: user!.isSuperAdmin ? '超管' : '管理员',
                  value: 'exp: ${user.adminExp}',
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
        style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white),
      ),
    );
  }

  Widget _buildStatBadge({required IconData icon, required String label, required String value, required Color color}) {
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
              Text(label, style: const TextStyle(fontSize: 10, color: Colors.white60)),
              Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAdminSection(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: GlassContainer(
        padding: const EdgeInsets.all(16),
        borderRadius: 16,
        blur: 10,
        opacity: 0.15,
        gradientColors: isDark ? [Colors.red[800]!, Colors.red[900]!] : [Colors.red[50]!, Colors.red[100]!],
        onTap: () {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
        },
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.admin_panel_settings, color: Colors.red, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '管理处',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '处理举报、审核内容',
                    style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
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
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EduScreen())),
              ),
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
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
                    MaterialPageRoute(builder: (_) => const ExamExtractScreen()),
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

  Widget _buildSettingsSection(BuildContext context, ThemeProvider themeProvider, AuthProvider authProvider, bool isDark) {
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
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
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
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
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
                  onChanged: (v) => _showLiquidGlassWarningDialog(context, themeProvider, v),
                  activeColor: Theme.of(context).primaryColor,
                ),
                isDark: isDark,
              ),
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
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
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
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
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.lock,
                iconColor: Colors.orange,
                title: '修改密码',
                isDark: isDark,
                onTap: () => _showChangePasswordDialog(context, authProvider),
              ),
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
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
                  side: BorderSide(color: isDark ? Colors.white24 : Colors.grey[300]!),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
    try {
      final dio = context.read<AuthProvider>().dio;
      final resp = await dio.get('/version');
      if (resp.statusCode == 200) {
        final data = resp.data;
        final version = data['version'] ?? '';
        final forceUpdate = data['force_update'] ?? false;
        final downloadUrl = data['download_url'] ?? 'https://gitee.com/chunhezi/SYLUlive/releases';
        final updateMsg = data['update_msg'] ?? '新版本可用';

        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(children: [
              Icon(Icons.system_update, color: Colors.blue),
              SizedBox(width: 8),
              Text('版本检查'),
            ]),
            content: Text('当前服务器版本: $version\n$updateMsg', style: const TextStyle(height: 1.5)),
            actions: [
              if (!forceUpdate)
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
              ElevatedButton.icon(
                onPressed: () {
                  launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.download, size: 18),
                label: const Text('下载更新'),
                style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).primaryColor, foregroundColor: Colors.white),
              ),
            ],
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('检查失败，请检查网络'), backgroundColor: Colors.red));
      }
    }
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
                  style: TextStyle(color: isDark ? Colors.white60 : Colors.grey[600], fontSize: 13)),
              if (trailing != null) trailing,
              if (trailing == null && onTap != null)
                Icon(Icons.chevron_right, color: isDark ? Colors.white30 : Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  void _showBackgroundPicker(BuildContext context, ThemeProvider themeProvider) {
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
            const Text('选择背景', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                        final imagePath = isAsset ? 'assets/images/${backgrounds[index]}' : backgrounds[index];
                        return GestureDetector(
                          onTap: () {
                            themeProvider.setBackgroundImage(backgrounds[index]);
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
                                    : NetworkImage(backgrounds[index]) as ImageProvider,
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
                  final image = await picker.pickImage(source: ImageSource.gallery);
                  if (image != null) {
                    final appDir = await getApplicationDocumentsDirectory();
                    final fileName = 'background_${DateTime.now().millisecondsSinceEpoch}${path.extension(image.path)}';
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

  void _showRestoreDefaultDialog(BuildContext context, ThemeProvider themeProvider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('恢复默认壁纸'),
        content: const Text('将清除当前自定义背景，所有页面恢复为系统默认壁纸。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              themeProvider.clearBackground();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已恢复默认壁纸'), backgroundColor: Colors.green),
              );
            },
            child: const Text('确认恢复', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showLiquidGlassWarningDialog(BuildContext context, ThemeProvider themeProvider, bool enable) {
    if (!enable) {
      themeProvider.setLiquidGlass(false);
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade400, size: 28),
          const SizedBox(width: 12),
          const Text('性能警告'),
        ]),
        content: const Text('液态玻璃效果基于模糊算法实现，在部分设备上可能会造成卡顿。', style: TextStyle(height: 1.5)),
        actions: [
          TextButton(onPressed: () { Navigator.pop(ctx); }, child: const Text('了解，但继续开启')),
          ElevatedButton(
            onPressed: () { Navigator.pop(ctx); themeProvider.setLiquidGlass(true); },
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
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
          child: InteractiveViewer(child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)),
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
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: '昵称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              final result = await authProvider.updateProfile(controller.text);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.success ? '更新成功' : (result.errorMessage ?? '更新失败')),
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

  void _showChangePasswordDialog(BuildContext context, AuthProvider authProvider) {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: oldController, decoration: const InputDecoration(labelText: '旧密码'), obscureText: true),
          const SizedBox(height: 16),
          TextField(controller: newController, decoration: const InputDecoration(labelText: '新密码'), obscureText: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              final result = await authProvider.changePassword(oldController.text, newController.text);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.success ? '修改成功' : (result.errorMessage ?? '修改失败')),
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
      final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}${path.extension(image.path)}';
      final savedPath = path.join(appDir.path, fileName);
      await File(image.path).copy(savedPath);
      final result = await authProvider.updateAvatar(savedPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.success ? '头像更新成功' : (result.errorMessage ?? '头像更新失败')),
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
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: Center(child: InteractiveViewer(child: Image.network(avatarUrl))),
      ),
    ));
  }

  void _showAboutDialog(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // App icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Theme.of(context).primaryColor,
                      Theme.of(context).primaryColor.withOpacity(0.6),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).primaryColor.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.school,
                  color: Colors.white,
                  size: 40,
                ),
              ),
              const SizedBox(height: 20),

              // App name
              Text(
                '沈理校园',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                '校园互助社交应用',
                style: TextStyle(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              Text(
                '版本 1.0.0',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              const SizedBox(height: 24),

              // Author
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_outline, size: 18, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    Text(
                      '作者：纯合子',
                      style: TextStyle(color: isDark ? Colors.white70 : Colors.grey.shade700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Contact buttons
              Text(
                'Bug反馈 / 联系作者',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // GitHub
                  _buildContactButton(
                    context,
                    icon: Icons.code,
                    label: 'GitHub',
                    color: Colors.grey.shade800,
                    onTap: () => _launchUrl('https://github.com/zhouwu97/SYLUlive'),
                  ),
                  const SizedBox(width: 12),
                  // Email
                  _buildContactButton(
                    context,
                    icon: Icons.email_outlined,
                    label: '邮箱',
                    color: Colors.red.shade400,
                    onTap: () => _copyToClipboard(context, '3170305904@qq.com', '邮箱地址已复制'),
                  ),
                  const SizedBox(width: 12),
                  // QQ
                  _buildContactButton(
                    context,
                    icon: Icons.chat_outlined,
                    label: 'QQ',
                    color: Colors.blue.shade400,
                    onTap: () => _launchUrl('mqqapi://card/show_pslcard?src_type=internal&version=1&uin=3170305904&card_type=person'),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Close button
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    '关闭',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text, String successMessage) {
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
}
