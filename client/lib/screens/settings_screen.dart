import 'dart:io';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../services/keep_alive_service.dart';
import '../services/wallpaper_prefetch_service.dart';
import '../utils/update_checker.dart';
import '../widgets/glass_container.dart';
import 'diagnostic_log_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _wallpaperBaseUrl = WallpaperPrefetchService.baseUrl;
  KeepAliveStatus _keepAliveStatus = const KeepAliveStatus.unsupported();
  bool _keepAliveBusy = false;
  bool _hideRecentsBusy = false;

  @override
  void initState() {
    super.initState();
    _loadKeepAliveStatus();
  }

  Future<void> _loadKeepAliveStatus() async {
    final status = await KeepAliveService.instance.status();
    if (!mounted) return;
    setState(() => _keepAliveStatus = status);
  }

  Future<void> _setKeepAliveEnabled(bool enabled) async {
    if (_keepAliveBusy) return;
    setState(() => _keepAliveBusy = true);
    final status = await KeepAliveService.instance.setEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _keepAliveStatus = status;
      _keepAliveBusy = false;
    });
    if (enabled) {
      await _showKeepAliveGuideDialog();
    }
  }

  Future<void> _setHideRecentsEnabled(bool enabled) async {
    if (_hideRecentsBusy) return;
    setState(() => _hideRecentsBusy = true);
    final status = await KeepAliveService.instance.setHideRecentsEnabled(
      enabled,
    );
    if (!mounted) return;
    setState(() {
      _keepAliveStatus = status;
      _hideRecentsBusy = false;
    });
  }

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
                  _buildSettingsSection(
                    context,
                    themeProvider,
                    authProvider,
                    isDark,
                  ),
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
      final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
      final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
      final imageProvider = isAsset
          ? AssetImage(ThemeProvider.resolveBundledAssetPath(bgPath))
              as ImageProvider
          : isLocalFile
              ? FileImage(File(bgPath)) as ImageProvider
              : NetworkImage(bgPath) as ImageProvider;
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildBackgroundImage(
            imageProvider: imageProvider,
            isDark: isDark,
            fillScreen: themeProvider.getBackgroundFillScreenFor(context),
            blur: themeProvider.backgroundBlur,
          ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3),
          ),
        ],
      );
    }
    return _buildDefaultBackground(isDark);
  }

  Widget _buildDefaultBackground(bool isDark) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    final defaultImage = isWide
        ? 'assets/images/tablet_default_landscape.png'
        : 'assets/images/morenbeijing.jpeg';
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundImage(
          imageProvider: AssetImage(defaultImage),
          alignment: Alignment.center,
          isDark: isDark,
          fillScreen: false,
          blur: context.read<ThemeProvider>().backgroundBlur,
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  Widget _buildBackgroundImage({
    required ImageProvider imageProvider,
    required bool isDark,
    required bool fillScreen,
    required double blur,
    Alignment alignment = Alignment.center,
  }) {
    if (fillScreen) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: alignment,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: 1.06,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              alignment: alignment,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(
                color:
                    isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
              ),
            ),
          ),
        ),
        Image(
          image: imageProvider,
          fit: BoxFit.contain,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildSettingsSection(
    BuildContext context,
    ThemeProvider themeProvider,
    AuthProvider authProvider,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 背景设置 — 独立卡片
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.wallpaper,
            iconColor: Colors.purple,
            title: '自定义背景',
            subtitle: '默认或竖屏时显示的背景',
            isDark: isDark,
            onTap: () => _showBackgroundPicker(context, themeProvider, false),
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.landscape,
            iconColor: Colors.purpleAccent,
            title: '横屏自定义背景',
            subtitle: '平板或宽屏下显示的专属横向背景',
            isDark: isDark,
            onTap: () => _showBackgroundPicker(context, themeProvider, true),
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
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
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.restore,
            iconColor: Colors.orange,
            title: '默认壁纸',
            subtitle: '恢复为系统默认背景',
            isDark: isDark,
            onTap: () => _showRestoreDefaultDialog(context, themeProvider),
          ),
        ),

        const SizedBox(height: 8),

        // 视觉效果 — 独立卡片
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.blur_on,
            iconColor: Colors.indigo,
            title: '液态玻璃效果',
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: themeProvider.liquidGlass,
                onChanged: (v) =>
                    _showLiquidGlassWarningDialog(context, themeProvider, v),
                activeColor: Theme.of(context).primaryColor,
              ),
            ),
            isDark: isDark,
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
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
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
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
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.battery_saver,
            iconColor: Colors.green,
            title: '后台保活',
            subtitle: _keepAliveSubtitle(),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: _keepAliveStatus.supported && _keepAliveStatus.enabled,
                onChanged: !_keepAliveStatus.supported || _keepAliveBusy
                    ? null
                    : _setKeepAliveEnabled,
                activeThumbColor: Theme.of(context).primaryColor,
              ),
            ),
            isDark: isDark,
            onTap: _keepAliveStatus.supported
                ? () => KeepAliveService.instance.openSettings()
                : null,
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.layers_clear,
            iconColor: Colors.deepPurple,
            title: '隐藏后台卡片',
            subtitle: _hideRecentsSubtitle(),
            trailing: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: _keepAliveStatus.supported &&
                    _keepAliveStatus.hideRecentsEnabled,
                onChanged: !_keepAliveStatus.supported || _hideRecentsBusy
                    ? null
                    : _setHideRecentsEnabled,
                activeThumbColor: Theme.of(context).primaryColor,
              ),
            ),
            isDark: isDark,
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
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
          ),
        ),

        const SizedBox(height: 8),

        // 账号 — 独立卡片
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.receipt_long_rounded,
            iconColor: Colors.blue,
            title: '查看日志',
            subtitle: '查看保活、推送和异常记录',
            isDark: isDark,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DiagnosticLogScreen()),
              );
            },
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.lock,
            iconColor: Colors.orange,
            title: '修改密码',
            isDark: isDark,
            onTap: () => _showChangePasswordDialog(context, authProvider),
          ),
        ),
        _buildSettingsRow(
          child: _buildSettingsTile(
            icon: Icons.info,
            iconColor: Colors.blue,
            title: '关于',
            isDark: isDark,
            onTap: () => _showAboutDialog(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () =>
                  UpdateChecker.check(context, showNoUpdateToast: true),
              icon: const Icon(Icons.system_update, size: 18),
              label: const Text('检查更新'),
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? Colors.white70 : Colors.grey[700],
                side: BorderSide(
                  color: isDark ? Colors.white24 : Colors.grey[300]!,
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
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

  String _keepAliveSubtitle() {
    if (!_keepAliveStatus.supported) return '当前平台不可用';
    if (!_keepAliveStatus.enabled) return '开启后按提示加入后台白名单，提升提醒稳定性';
    if (_keepAliveStatus.serviceRunning) {
      return _keepAliveStatus.isIgnoringBatteryOptimizations
          ? '运行中，后台提醒更稳定'
          : '运行中，请允许自启动和后台无限制';
    }
    return '已开启，等待系统启动保活服务';
  }

  String _hideRecentsSubtitle() {
    if (!_keepAliveStatus.supported) return '当前平台不可用';
    return _keepAliveStatus.hideRecentsEnabled
        ? '已隐藏最近任务卡片，默认关闭，可随时关掉'
        : '默认关闭，开启后应用不会显示在最近任务列表';
  }

  Future<void> _showKeepAliveGuideDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('后台保活提示'),
        content: const Text(
          '请在接下来的系统页面里开启以下权限或设置：\n\n'
          '• 电池使用：无限制\n'
          '• 允许应用自启动\n'
          '• 允许后台活动\n'
          '• 最近任务中锁定应用\n\n'
          '保活状态请看常驻通知或快捷设置开关。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await KeepAliveService.instance.openSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
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
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark ? Colors.white54 : Colors.grey[600],
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing,
              if (trailing == null && onTap != null)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: isDark ? Colors.white30 : Colors.grey[400],
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBackgroundPicker(
    BuildContext context,
    ThemeProvider themeProvider,
    bool isLandscape,
  ) {
    final backgrounds = [
      if (isLandscape) ...[
        'tablet_landscape_01.png',
        'tablet_landscape_02.png',
        'tablet_landscape_03.png',
        'tablet_landscape_04.png',
        'tablet_landscape_05.png',
        'tablet_landscape_06.png',
        'tablet_landscape_07.png',
        'tablet_landscape_08.png',
      ],
      if (!isLandscape) ...[
        'phone_wallpaper_01.png',
        'phone_wallpaper_02.png',
        'phone_wallpaper_03.png',
        'phone_wallpaper_04.png',
      ],
    ];

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        final size = MediaQuery.of(context).size;
        final maxDialogWidth = isLandscape ? 860.0 : 620.0;
        final previewRatio = isLandscape ? 16 / 9 : 9 / 16;
        final crossAxisCount = isLandscape
            ? (size.width >= 900 ? 3 : 2)
            : (size.width >= 760 ? 4 : 3);
        final dialogWidth =
            size.width < maxDialogWidth + 48 ? size.width - 48 : maxDialogWidth;
        final gridMaxHeight = size.height * 0.58;

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: dialogWidth,
              maxHeight: size.height * 0.86,
            ),
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              elevation: 18,
              shadowColor: Colors.black38,
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            isLandscape ? '选择横屏背景' : '选择背景',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: gridMaxHeight),
                        child: GridView.builder(
                          shrinkWrap: true,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: previewRatio,
                          ),
                          itemCount: backgrounds.length,
                          itemBuilder: (context, index) {
                            final value = backgrounds[index];
                            final imagePath = _wallpaperThumbnailAsset(value);
                            return GestureDetector(
                              onTap: () async {
                                final navigator = Navigator.of(context);
                                await _useBundledBackground(
                                  context,
                                  themeProvider,
                                  value,
                                  isLandscape,
                                );
                                if (navigator.mounted) navigator.pop();
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      image: DecorationImage(
                                        image: AssetImage(imagePath),
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                  Positioned(
                                    right: 8,
                                    bottom: 8,
                                    child: Material(
                                      color: Colors.black.withOpacity(0.52),
                                      borderRadius: BorderRadius.circular(18),
                                      child: InkWell(
                                        onTap: () => _editBundledBackground(
                                          context,
                                          themeProvider,
                                          value,
                                          isLandscape,
                                        ),
                                        borderRadius: BorderRadius.circular(18),
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Icon(
                                            Icons.crop,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _pickerActionButton(
                            label: '直接使用',
                            icon: Icons.photo_library,
                            onTap: () => _pickGalleryBackground(
                              context,
                              themeProvider,
                              isLandscape,
                              edit: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _pickerActionButton(
                            label: '编辑图片',
                            icon: Icons.crop,
                            onTap: () => _pickGalleryBackground(
                              context,
                              themeProvider,
                              isLandscape,
                              edit: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _setBackground(
    ThemeProvider themeProvider,
    bool isLandscape,
    String imagePath, {
    bool fillScreen = false,
  }) {
    if (isLandscape) {
      themeProvider.setLandscapeBackgroundImage(
        imagePath,
        fillScreen: fillScreen,
      );
    } else {
      themeProvider.setBackgroundImage(imagePath, fillScreen: fillScreen);
    }
  }

  String? _remoteWallpaperUrl(String assetName) {
    if (!assetName.startsWith('tablet_landscape_') &&
        !assetName.startsWith('phone_wallpaper_')) {
      return null;
    }
    return '$_wallpaperBaseUrl/$assetName';
  }

  String _wallpaperThumbnailAsset(String assetName) {
    return 'assets/images/wallpaper_thumbs/${path.basenameWithoutExtension(assetName)}.jpg';
  }

  Future<void> _useBundledBackground(
    BuildContext context,
    ThemeProvider themeProvider,
    String assetName,
    bool isLandscape,
  ) async {
    final remoteUrl = _remoteWallpaperUrl(assetName);
    if (remoteUrl == null) {
      _setBackground(themeProvider, isLandscape, assetName, fillScreen: true);
      return;
    }

    if (kIsWeb) {
      _setBackground(themeProvider, isLandscape, remoteUrl, fillScreen: true);
      return;
    }

    if (!context.read<AuthProvider>().isLoggedIn) {
      _setBackground(
        themeProvider,
        isLandscape,
        _wallpaperThumbnailAsset(assetName),
        fillScreen: true,
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('当前使用压缩预览图，登录后可自动下载高清壁纸'),
          ),
        );
      }
      return;
    }

    try {
      final savedPath = await _downloadWallpaper(remoteUrl, assetName);
      _setBackground(themeProvider, isLandscape, savedPath, fillScreen: true);
    } catch (e) {
      debugPrint('Download wallpaper failed: ');
      _setBackground(
        themeProvider,
        isLandscape,
        _wallpaperThumbnailAsset(assetName),
        fillScreen: true,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('高清壁纸下载失败，当前使用压缩预览图')));
      }
    }
  }

  Future<String> _downloadWallpaper(String url, String fileName) async {
    final savedPath = await WallpaperPrefetchService.localPathFor(fileName);
    await WallpaperPrefetchService.downloadAndVerifyImage(
      Dio(),
      url,
      savedPath,
    );
    return savedPath;
  }

  Future<void> _editBundledBackground(
    BuildContext context,
    ThemeProvider themeProvider,
    String assetName,
    bool isLandscape,
  ) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('网页版可直接使用内置壁纸，编辑请从相册选择图片')));
      return;
    }

    try {
      final remoteUrl = _remoteWallpaperUrl(assetName);
      final useRemote =
          remoteUrl != null && context.read<AuthProvider>().isLoggedIn;

      String? sourcePath;
      if (useRemote) {
        try {
          sourcePath = await _downloadWallpaper(remoteUrl, assetName);
        } catch (e) {
          debugPrint('Download wallpaper for edit failed: $e');
        }
      }

      sourcePath ??= await _copyAssetToTempFile(
        'wallpaper_thumbs/${path.basenameWithoutExtension(assetName)}.jpg',
      );

      String? savedPath;
      try {
        savedPath = await _cropAndSaveBackground(
          sourcePath,
          isLandscape: isLandscape,
        );
      } catch (e) {
        debugPrint('Crop failed, possibly corrupted file: $e');
        if (useRemote &&
            sourcePath.isNotEmpty &&
            !sourcePath.contains('background_source_')) {
          try {
            await File(sourcePath).delete();
          } catch (_) {}
          final fallbackSource = await _copyAssetToTempFile(
            'wallpaper_thumbs/${path.basenameWithoutExtension(assetName)}.jpg',
          );
          savedPath = await _cropAndSaveBackground(
            fallbackSource,
            isLandscape: isLandscape,
          );
        } else {
          rethrow;
        }
      }

      if (savedPath == null) return;
      _setBackground(themeProvider, isLandscape, savedPath, fillScreen: true);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Edit bundled background failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('编辑背景失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<String> _copyAssetToTempFile(String assetName) async {
    final data = await rootBundle.load(
      ThemeProvider.resolveBundledAssetPath(assetName),
    );
    final tempDir = await getTemporaryDirectory();
    final sourcePath = path.join(
      tempDir.path,
      'background_source_${DateTime.now().millisecondsSinceEpoch}_${path.basename(assetName)}',
    );
    await File(sourcePath).writeAsBytes(data.buffer.asUint8List());
    return sourcePath;
  }

  Future<void> _pickGalleryBackground(
    BuildContext context,
    ThemeProvider themeProvider,
    bool isLandscape, {
    required bool edit,
  }) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    try {
      final savedPath = edit
          ? await _cropAndSaveBackground(image.path, isLandscape: isLandscape)
          : await _saveBackgroundFile(image.path, isLandscape: isLandscape);
      if (savedPath == null) return;
      _setBackground(themeProvider, isLandscape, savedPath, fillScreen: edit);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Pick gallery background failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置背景失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<String?> _cropAndSaveBackground(
    String sourcePath, {
    required bool isLandscape,
  }) async {
    final screenSize = MediaQuery.sizeOf(context);
    final isWideScreen = screenSize.width > screenSize.height;
    final targetRatioX = isLandscape
        ? (isWideScreen ? screenSize.width : 16.0)
        : (isWideScreen ? 9.0 : screenSize.width);
    final targetRatioY = isLandscape
        ? (isWideScreen ? screenSize.height : 9.0)
        : (isWideScreen ? 16.0 : screenSize.height);
    final cropped = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      aspectRatio: CropAspectRatio(ratioX: targetRatioX, ratioY: targetRatioY),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: isLandscape ? '裁剪横屏背景' : '裁剪竖屏背景',
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          statusBarColor: Colors.black,
          backgroundColor: Colors.black,
          initAspectRatio: isWideScreen || isLandscape
              ? CropAspectRatioPreset.ratio16x9
              : CropAspectRatioPreset.original,
          lockAspectRatio: true,
        ),
        IOSUiSettings(
          title: isLandscape ? '裁剪横屏背景' : '裁剪竖屏背景',
          aspectRatioLockEnabled: true,
          resetButtonHidden: true,
        ),
      ],
    );
    if (cropped == null) return null;
    return _saveBackgroundFile(cropped.path, isLandscape: isLandscape);
  }

  Future<String> _saveBackgroundFile(
    String sourcePath, {
    required bool isLandscape,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final extension = path.extension(sourcePath).isEmpty
        ? '.jpg'
        : path.extension(sourcePath);
    final fileName =
        '${isLandscape ? 'landscape_background' : 'background'}_${DateTime.now().millisecondsSinceEpoch}$extension';
    final savedPath = path.join(appDir.path, fileName);
    final xf = XFile(sourcePath);
    final bytes = await xf.readAsBytes();
    await File(savedPath).writeAsBytes(bytes);
    return savedPath;
  }

  Widget _pickerActionButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRestoreDefaultDialog(
    BuildContext context,
    ThemeProvider themeProvider,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('恢复默认壁纸'),
        content: const Text('将清除当前自定义背景，所有页面恢复为系统默认壁纸。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              themeProvider.clearBackground();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已恢复默认壁纸'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('确认恢复', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showLiquidGlassWarningDialog(
    BuildContext context,
    ThemeProvider themeProvider,
    bool enable,
  ) {
    if (!enable) {
      themeProvider.setLiquidGlass(false);
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange.shade400,
              size: 28,
            ),
            const SizedBox(width: 12),
            const Text('性能警告'),
          ],
        ),
        content: const Text(
          '液态玻璃效果基于模糊算法实现，在部分设备上可能会造成卡顿。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('了解，但继续开启'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              themeProvider.setLiquidGlass(true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('开启'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditProfileDialog(
    BuildContext context,
    AuthProvider authProvider,
  ) async {
    final controller = TextEditingController(text: authProvider.user?.nickname);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑资料'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '昵称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final result = await authProvider.updateProfile(controller.text);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      result.success ? '更新成功' : (result.errorMessage ?? '更新失败'),
                    ),
                    backgroundColor: result.success ? Colors.green : Colors.red,
                  ),
                );
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
    BuildContext context,
    AuthProvider authProvider,
  ) async {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldController,
              decoration: const InputDecoration(labelText: '旧密码'),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: newController,
              decoration: const InputDecoration(labelText: '新密码'),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final result = await authProvider.changePassword(
                oldController.text,
                newController.text,
              );
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      result.success ? '修改成功' : (result.errorMessage ?? '修改失败'),
                    ),
                    backgroundColor: result.success ? Colors.green : Colors.red,
                  ),
                );
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
            child: Opacity(opacity: value, child: child),
          );
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1E1E2E).withOpacity(0.8)
                : Colors.white.withOpacity(0.9),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.1)
                  : Colors.white.withOpacity(0.5),
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
                      return Transform.scale(scale: scale, child: child);
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
                      child: const Icon(
                        Icons.school_rounded,
                        color: Colors.white,
                        size: 48,
                      ),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
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
                            ? [
                                Colors.white.withOpacity(0.05),
                                Colors.white.withOpacity(0.02),
                              ]
                            : [
                                const Color(0xFFF4F7FC),
                                const Color(0xFFEEF2F9),
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDark
                            ? Colors.white12
                            : Colors.black.withOpacity(0.05),
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
                              child: Icon(
                                Icons.code_rounded,
                                size: 20,
                                color: primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '开发者',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Colors.white54
                                        : const Color(0xFF9094A6),
                                  ),
                                ),
                                Text(
                                  '纯合子',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF2D3142),
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
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF4F5568),
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
                          onTapOverride: () =>
                              _copyToClipboard(context, '1076639620', '复制成功'),
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
                          onTapOverride: () => _copyToClipboard(
                            context,
                            '3170305904@qq.com',
                            '邮箱已复制到剪贴板',
                          ),
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

  Widget _aboutLink(
    BuildContext context,
    IconData icon,
    String label,
    String? url,
    bool isDark,
    Color color, {
    VoidCallback? onTapOverride,
  }) {
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
            color: isDark
                ? Colors.white.withOpacity(0.04)
                : Colors.black.withOpacity(0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.05)
                  : Colors.black.withOpacity(0.05),
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
                    color: isDark
                        ? Colors.white.withOpacity(0.9)
                        : const Color(0xFF2D3142),
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
    BuildContext context,
    String text,
    String successMessage,
  ) {
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
