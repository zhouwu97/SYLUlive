import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/platform_capabilities.dart';
import '../providers/auth_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/theme_provider.dart';
import '../services/grade_reminder_service.dart';
import '../services/keep_alive_service.dart';
import '../services/push_settings_service.dart';
import '../widgets/about_app_sheet.dart';
import '../widgets/campus/campus_theme.dart';
import '../widgets/settings/settings_account_header.dart';
import '../widgets/settings/settings_page_scaffold.dart';
import '../widgets/settings/settings_section.dart';
import '../widgets/settings/settings_status_badge.dart';
import '../widgets/settings/settings_tile.dart';
import 'account_security_screen.dart';
import 'login_screen.dart';
import 'privacy_center_screen.dart';
import 'settings/appearance_settings_screen.dart';
import 'settings/diagnostics_settings_screen.dart';
import 'settings/notification_background_settings_screen.dart';

/// 沈理校园 设置中心 主入口页面 (完全对齐设计效果图)
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  KeepAliveStatus _keepAliveStatus = const KeepAliveStatus.unsupported();
  RemotePushSnapshot? _pushSnapshot;
  bool _loadingState = true;

  @override
  void initState() {
    super.initState();
    _loadSummaryStates();
  }

  Future<void> _loadSummaryStates() async {
    final status = await KeepAliveService.instance.status();
    final snapshot = await PushSettingsService.getPushSnapshot();
    if (mounted) {
      setState(() {
        _keepAliveStatus = status;
        _pushSnapshot = snapshot;
        _loadingState = false;
      });
    }
  }

  String _getAppearanceSummary(ThemeProvider theme) {
    final modeText = theme.isCleanBackgroundMode ? '简洁模式' : '自定义背景';
    final brightnessText = theme.isDarkMode ? '深色' : '浅色';
    final cardText = theme.liquidGlass ? '液态玻璃' : '标准卡片';
    return '$modeText · $brightnessText · $cardText';
  }

  String _getNotificationSummary() {
    if (_loadingState) return '正在读取通知与后台状态...';
    if (!PlatformCapabilities.current.supportsJPush) {
      return '当前平台不支持远程推送';
    }
    final snapshot = _pushSnapshot;
    final pushOptedIn = snapshot?.optedIn == true;
    final pushText = pushOptedIn ? '远程推送已开启' : '远程推送关闭';

    String keepAliveText;
    if (!_keepAliveStatus.supported) {
      keepAliveText = '后台服务未开启';
    } else if (_keepAliveStatus.serviceRunning) {
      keepAliveText = '后台服务运行中';
    } else if (_keepAliveStatus.enabled) {
      keepAliveText = '后台待启动';
    } else {
      keepAliveText = '后台服务未开启';
    }
    return '$pushText · $keepAliveText';
  }

  int _calculatePendingIssues() {
    final snapshot = _pushSnapshot;
    if (snapshot == null || !snapshot.supported || !snapshot.optedIn) {
      return 0;
    }
    int issues = 0;
    if (!snapshot.notificationsEnabled) {
      issues++;
    }
    if (snapshot.registrationId == null || snapshot.registrationId!.isEmpty) {
      issues++;
    }
    if (snapshot.privateChannelBlocked) {
      issues++;
    }
    if (snapshot.aliasState == 'pending_bind') {
      issues++;
    }
    return issues;
  }

  Future<void> _handleLogout(
    BuildContext context,
    AuthProvider authProvider,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text(
          '退出后将清理本机教务会话和当前账号的课表状态，下次使用需要重新登录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: CampusTheme.red,
            ),
            child: const Text('退出'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    final userId = authProvider.user?.id.toString();
    final eduProvider = context.read<EduProvider>();
    final courseProvider = context.read<CourseScheduleProvider>();

    if (userId != null) {
      await GradeReminderService.instance.clearForUser(userId);
    }
    await eduProvider.clearLocalSession();
    courseProvider.clearAllUserState();
    await authProvider.logout();

    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final authProvider = context.watch<AuthProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLoggedIn = authProvider.isLoggedIn && authProvider.user != null;

    final pendingIssues = _calculatePendingIssues();

    return SettingsPageScaffold(
      title: '设置',
      onRefresh: _loadSummaryStates,
      children: [
        // 账号摘要卡片 (完美对齐效果图)
        const SettingsAccountHeader(),

        // 常用设置 (与效果图 100% 对齐)
        SettingsSection(
          title: '常用设置',
          children: [
            SettingsTile(
              icon: Icons.wb_sunny_outlined,
              title: '外观与显示',
              subtitle: _getAppearanceSummary(themeProvider),
              trailing: SettingsStatusBadge(
                label: themeProvider.isCleanBackgroundMode ? '简洁' : '自定义',
                type: SettingsStatusBadgeType.success,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AppearanceSettingsScreen(),
                  ),
                ).then((_) => _loadSummaryStates());
              },
            ),
            SettingsTile(
              icon: Icons.notifications_none_rounded,
              title: '通知与后台',
              subtitle: _getNotificationSummary(),
              trailing: pendingIssues > 0
                  ? SettingsStatusBadge(
                      label: '$pendingIssues项待处理',
                      type: SettingsStatusBadgeType.warning,
                    )
                  : null,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const NotificationBackgroundSettingsScreen(),
                  ),
                ).then((_) => _loadSummaryStates());
              },
            ),
          ],
        ),

        // 账号与隐私 (与效果图 100% 对齐)
        SettingsSection(
          title: '账号与隐私',
          children: [
            SettingsTile(
              icon: Icons.shield_outlined,
              title: '账号与安全',
              subtitle: '学号、邮箱、密码和教务授权',
              onTap: () {
                if (isLoggedIn) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AccountSecurityScreen(),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LoginScreen(),
                    ),
                  );
                }
              },
            ),
            SettingsTile(
              icon: Icons.lock_outline_rounded,
              title: '隐私与数据',
              subtitle: '授权管理、查阅导出与账号注销',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PrivacyCenterScreen(),
                  ),
                );
              },
            ),
          ],
        ),

        // 支持与其他 (与效果图 100% 对齐)
        SettingsSection(
          title: '支持与其他',
          children: [
            SettingsTile(
              icon: Icons.build_outlined,
              title: '诊断与反馈',
              subtitle: '通知诊断、运行日志和问题反馈',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DiagnosticsSettingsScreen(),
                  ),
                ).then((_) => _loadSummaryStates());
              },
            ),
            SettingsTile(
              icon: Icons.info_outline_rounded,
              title: '关于沈理校园',
              subtitle: '版本 1.5.22 · 检查更新与开源信息',
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const AboutAppSheet(),
                );
              },
            ),
          ],
        ),

        // 退出登录按钮卡片 (与效果图 100% 对齐)
        if (isLoggedIn) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: CampusTheme.red.withValues(alpha: 0.3),
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => _handleLogout(context, authProvider),
                child: const SizedBox(
                  height: 50,
                  child: Center(
                    child: Text(
                      '退出登录',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: CampusTheme.red,
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
}
