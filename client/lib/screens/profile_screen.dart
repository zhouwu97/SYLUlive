import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/edu_provider.dart';
import '../widgets/glass_container.dart';
import 'edu_screen.dart';

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
          if (!themeProvider.isBackgroundVisible('profile'))
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
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  const Color(0xFF1A1A2E),
                  const Color(0xFF16213E),
                  const Color(0xFF0F3460),
                ]
              : [
                  const Color(0xFF667EEA),
                  const Color(0xFF764BA2),
                  const Color(0xFFF093FB),
                ],
        ),
      ),
    );
  }

  Widget _buildHeader(user, AuthProvider authProvider, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // 头像
          GlassContainer(
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
                      child: Image.network(
                        user!.avatar,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _buildAvatarPlaceholder(user),
                      ),
                    )
                  : _buildAvatarPlaceholder(user),
            ),
          ),

          const SizedBox(height: 20),

          Text(
            user?.nickname ?? '未登录',
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),

          const SizedBox(height: 8),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '学号: ${user?.studentId ?? "-"}',
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
              Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
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
          // TODO: 跳转到管理面板
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('管理面板开发中')),
          );
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

  Widget _buildSettingsSection(BuildContext context, ThemeProvider themeProvider, AuthProvider authProvider, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 教务系统
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildSettingsCard(
            isDark,
            children: [
              _buildSettingsTile(
                icon: Icons.school,
                iconColor: Colors.blue,
                title: '教务系统',
                subtitle: context.watch<EduProvider>().isBound ? '已绑定' : '未绑定',
                isDark: isDark,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EduScreen())),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

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
                icon: Icons.visibility,
                iconColor: Colors.teal,
                title: '背景透明度',
                trailing: SizedBox(
                  width: 150,
                  child: Slider(
                    value: themeProvider.backgroundTransparency,
                    onChanged: (v) => themeProvider.setBackgroundTransparency(v),
                    activeColor: Theme.of(context).primaryColor,
                  ),
                ),
                isDark: isDark,
              ),
              Divider(height: 1, indent: 68, color: isDark ? Colors.white10 : Colors.grey[200]),
              _buildSettingsTile(
                icon: Icons.public,
                iconColor: Colors.green,
                title: '背景应用范围',
                trailing: Text(
                  themeProvider.backgroundScope == BackgroundScope.global ? '全局' : '仅"我"',
                  style: TextStyle(color: isDark ? Colors.white60 : Colors.grey[600]),
                ),
                isDark: isDark,
                onTap: () => _showScopePicker(context, themeProvider),
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
                  onChanged: (v) => themeProvider.setLiquidGlass(v),
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
            ],
          ),
        ),

        // 退出登录
        Padding(
          padding: const EdgeInsets.all(16),
          child: GradientButton(
            text: '退出登录',
            gradientColors: [Colors.red[400]!, Colors.red[600]!],
            onPressed: () async {
              await authProvider.logout();
            },
          ),
        ),
      ],
    );
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
                Text(subtitle, style: TextStyle(color: isDark ? Colors.white60 : Colors.grey[600])),
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

  void _showScopePicker(BuildContext context, ThemeProvider themeProvider) {
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
            const Text('背景应用范围', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('全局'),
              subtitle: const Text('所有页面显示背景'),
              trailing: themeProvider.backgroundScope == BackgroundScope.global
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                themeProvider.setBackgroundScope(BackgroundScope.global);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('仅"我"'),
              subtitle: const Text('仅在个人中心和私信页面显示'),
              trailing: themeProvider.backgroundScope == BackgroundScope.meOnly
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                themeProvider.setBackgroundScope(BackgroundScope.meOnly);
                Navigator.pop(context);
              },
            ),
          ],
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
              await authProvider.updateProfile(controller.text);
              if (context.mounted) Navigator.pop(context);
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: oldController, decoration: const InputDecoration(labelText: '旧密码'), obscureText: true),
            const SizedBox(height: 16),
            TextField(controller: newController, decoration: const InputDecoration(labelText: '新密码'), obscureText: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              final ok = await authProvider.changePassword(oldController.text, newController.text);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? '修改成功' : '修改失败')));
              }
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }
}