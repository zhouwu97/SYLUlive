import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../utils/update_checker.dart';
import '../widgets/glass_container.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final authProvider = context.watch<AuthProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('设置'),
      ),
      body: Stack(
        children: [
          _buildBackground(themeProvider, isDark),
          SafeArea(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              children: [
                _buildSettingsSection(context, themeProvider, authProvider, isDark),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    String? bgPath = themeProvider.getBackgroundImageFor(context);
    
    if (bgPath != null && bgPath.isNotEmpty) {
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark))
            : bgPath.startsWith('/')
                ? Image.file(File(bgPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark))
                : Image.network(bgPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark)),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3)),
      ]);
    }
    return _buildDefaultBackground(isDark);
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

  Widget _buildSettingsSection(BuildContext context,
      ThemeProvider themeProvider, AuthProvider authProvider, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 背景设置 — 独立卡片
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.wallpaper,
          iconColor: Colors.purple,
          title: '自定义背景',
          subtitle: '默认或竖屏时显示的背景',
          isDark: isDark,
          onTap: () => _showBackgroundPicker(context, themeProvider, false),
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.landscape,
          iconColor: Colors.purpleAccent,
          title: '横屏自定义背景',
          subtitle: '平板或宽屏下显示的专属横向背景',
          isDark: isDark,
          onTap: () => _showBackgroundPicker(context, themeProvider, true),
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.opacity,
          iconColor: Colors.teal,
          title: '组件透明度',
          trailing: SizedBox(
            width: 120,
            height: 32,
            child: Slider(
              value: themeProvider.componentOpacity,
              min: 0.0,
              max: 1.0,
              onChanged: (v) => themeProvider.setComponentOpacity(v),
              activeColor: Theme.of(context).primaryColor,
            ),
          ),
          isDark: isDark,
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.restore,
          iconColor: Colors.orange,
          title: '默认壁纸',
          subtitle: '恢复为系统默认背景',
          isDark: isDark,
          onTap: () => _showRestoreDefaultDialog(context, themeProvider),
        )),

        const SizedBox(height: 8),

        // 视觉效果 — 独立卡片
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.blur_on,
          iconColor: Colors.indigo,
          title: '液态玻璃效果',
          trailing: Transform.scale(
            scale: 0.8,
            child: Switch(
              value: themeProvider.liquidGlass,
              onChanged: (v) => _showLiquidGlassWarningDialog(context, themeProvider, v),
              activeColor: Theme.of(context).primaryColor,
            ),
          ),
          isDark: isDark,
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.navigation,
          iconColor: Colors.orange,
          title: '悬浮底栏',
          trailing: Transform.scale(
            scale: 0.8,
            child: Switch(
              value: themeProvider.floatingNavBar,
              onChanged: (v) => themeProvider.setFloatingNavBar(v),
              activeColor: Theme.of(context).primaryColor,
            ),
          ),
          isDark: isDark,
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.swipe,
          iconColor: Colors.blue,
          title: '预测性返回手势',
          subtitle: 'Android 侧滑返回时预览上一页，关闭后仅顶部返回按钮可用',
          trailing: Transform.scale(
            scale: 0.8,
            child: Switch(
              value: themeProvider.predictiveBack,
              onChanged: (v) => themeProvider.setPredictiveBack(v),
              activeColor: Theme.of(context).primaryColor,
            ),
          ),
          isDark: isDark,
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.dark_mode,
          iconColor: isDark ? Colors.indigo : Colors.indigo,
          title: '夜间模式',
          trailing: Transform.scale(
            scale: 0.8,
            child: Switch(
              value: themeProvider.isDarkMode,
              onChanged: (v) => themeProvider.setDarkMode(v),
              activeColor: Theme.of(context).primaryColor,
            ),
          ),
          isDark: isDark,
        )),

        const SizedBox(height: 8),

        // 账号 — 独立卡片
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.person,
          iconColor: Colors.blue,
          title: '编辑资料',
          isDark: isDark,
          onTap: () => _showEditProfileDialog(context, authProvider),
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.lock,
          iconColor: Colors.orange,
          title: '修改密码',
          isDark: isDark,
          onTap: () => _showChangePasswordDialog(context, authProvider),
        )),
        _buildSettingsRow(child: _buildSettingsTile(
          icon: Icons.info,
          iconColor: Colors.blue,
          title: '关于',
          isDark: isDark,
          onTap: () => _showAboutDialog(context),
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => UpdateChecker.check(context, showNoUpdateToast: true),
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

        // 退出登录
        if (authProvider.isLoggedIn) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  colors: [Colors.red[400]!, Colors.red[600]!],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    // 登出前清空课表等关联状态，防止跨账号数据泄漏
                    context.read<CourseScheduleProvider>().clearAllUserState();
                    await authProvider.logout();
                    if (context.mounted) {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Text(
                        '退出登录',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 独立的设置卡片行（每个设置项单独一张毛玻璃卡片）
  Widget _buildSettingsRow({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
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
                Icon(Icons.chevron_right, size: 18,
                    color: isDark ? Colors.white30 : Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  void _showBackgroundPicker(
      BuildContext context, ThemeProvider themeProvider, bool isLandscape) {
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
            Text(isLandscape ? '选择横屏背景' : '选择背景',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                            if (isLandscape) {
                              themeProvider.setLandscapeBackgroundImage(backgrounds[index]);
                            } else {
                              themeProvider.setBackgroundImage(backgrounds[index]);
                            }
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
                    if (isLandscape) {
                      themeProvider.setLandscapeBackgroundImage(savedPath);
                    } else {
                      themeProvider.setBackgroundImage(savedPath);
                    }
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

  Future<void> _showEditProfileDialog(BuildContext context, AuthProvider authProvider) async {
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

  Future<void> _showChangePasswordDialog(
      BuildContext context, AuthProvider authProvider) async {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    await showDialog(
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
    oldController.dispose();
    newController.dispose();
  }

  void _showAboutDialog(BuildContext context) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;
    if (!context.mounted) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Transform.translate(
            offset: Offset(0, 50 * (1 - value)),
            child: Opacity(
              opacity: value,
              child: child,
            ),
          );
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E2E).withOpacity(0.8) : Colors.white.withOpacity(0.9),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: primary.withOpacity(isDark ? 0.2 : 0.1),
                blurRadius: 40,
                spreadRadius: 5,
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 拖拽指示条
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 24),
                        child: Container(
                          width: 48,
                          height: 5,
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white24 : Colors.grey[300],
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // 动态 App 图标
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.8, end: 1.0),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.elasticOut,
                        builder: (context, scale, child) {
                          return Transform.scale(
                            scale: scale,
                            child: child,
                          );
                        },
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [primary, primary.withOpacity(0.6)],
                            ),
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withOpacity(0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.school_rounded, color: Colors.white, size: 48),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // 标题与版本号
                      Text(
                        '沈理校园',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                          color: isDark ? Colors.white : const Color(0xFF2D3142),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '一款为沈理人写的开源校园工具',
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? Colors.white54 : const Color(0xFF9094A6),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: primary.withOpacity(0.2)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified, size: 14, color: primary),
                            const SizedBox(width: 6),
                            Text(
                              'Version $currentVersion',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // 开发者卡片 - 采用流光渐变设计
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: isDark
                                ? [Colors.white.withOpacity(0.05), Colors.white.withOpacity(0.02)]
                                : [const Color(0xFFF4F7FC), const Color(0xFFEEF2F9)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isDark ? Colors.white12 : Colors.black.withOpacity(0.05),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: primary.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(Icons.code_rounded, size: 20, color: primary),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '开发者',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? Colors.white54 : const Color(0xFF9094A6),
                                      ),
                                    ),
                                    Text(
                                      '纯合子',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: isDark ? Colors.white : const Color(0xFF2D3142),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '用爱发电，写个自己觉得好用的课表和论坛。',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.6,
                                color: isDark ? Colors.white70 : const Color(0xFF4F5568),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 联系与源码按钮组
                      _aboutLink(
                        context,
                        Icons.device_hub_rounded,
                        '开源仓库与源码',
                        'https://github.com/zhouwu97/SYLUlive',
                        isDark,
                        primary,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _aboutLink(
                              context,
                              Icons.group_rounded,
                              '加入群聊',
                              null,
                              isDark,
                              Colors.blue,
                              onTapOverride: () => _copyToClipboard(context, '1076639620', '复制成功'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _aboutLink(
                              context,
                              Icons.email_rounded,
                              '联系作者',
                              null,
                              isDark,
                              Colors.orange,
                              onTapOverride: () => _copyToClipboard(context, '3170305904@qq.com', '邮箱已复制到剪贴板'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ),
      ),
    );
  }

  Widget _aboutLink(BuildContext context, IconData icon, String label, String? url, bool isDark, Color color, {VoidCallback? onTapOverride}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTapOverride ?? (url != null ? () => _launchUrl(url) : null),
        borderRadius: BorderRadius.circular(16),
        highlightColor: color.withOpacity(0.1),
        splashColor: color.withOpacity(0.2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white.withOpacity(0.9) : const Color(0xFF2D3142),
                  ),
                ),
              ),
            ],
          ),
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
}
