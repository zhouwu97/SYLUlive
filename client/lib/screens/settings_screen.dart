import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/platform_capabilities.dart';
import '../providers/auth_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/theme_provider.dart';
import '../services/keep_alive_service.dart';
import '../services/push_settings_service.dart';
import '../widgets/campus/campus_theme.dart';
import '../widgets/settings/settings_account_header.dart';
import '../widgets/settings/settings_page_scaffold.dart';
import '../widgets/settings/settings_section.dart';
import '../widgets/settings/settings_status_badge.dart';
import '../widgets/settings/settings_tile.dart';
import 'account_security_screen.dart';
import 'login_screen.dart';
import 'privacy_center_screen.dart';
import 'academic_data_settings_screen.dart';
import '../features/academic/application/academic_session_controller.dart';

import 'settings/appearance_settings_screen.dart';
import 'settings/diagnostics_settings_screen.dart';
import 'settings/notification_background_settings_screen.dart';
import '../widgets/about_app_sheet.dart';

/// 简化后的重构版设置首页
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
    RemotePushSnapshot? snapshot;
    if (PlatformCapabilities.current.supportsJPush) {
      snapshot = await PushSettingsService.getPushSnapshot();
    }

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
    return '$modeText · $brightnessText · ${theme.bottomNavStyle.label}';
  }

  String _getNotificationSummary() {
    if (_loadingState) return '正在读取通知与后台状态...';
    if (!PlatformCapabilities.current.supportsJPush) {
      return '当前平台不支持远程推送';
    }
    final snapshot = _pushSnapshot;
    String pushText;
    if (snapshot == null) {
      pushText = '正在读取推送状态';
    } else {
      final status = resolveRemotePushStatus(snapshot);
      switch (status) {
        case ResolvedPushStatus.ready:
          pushText = '远程推送已开启';
          break;
        case ResolvedPushStatus.configuring:
          pushText = '远程推送配置中';
          break;
        case ResolvedPushStatus.permissionDenied:
          pushText = '系统通知权限受限';
          break;
        case ResolvedPushStatus.registrationFailed:
          pushText = '设备注册失败';
          break;
        case ResolvedPushStatus.channelUnavailable:
          pushText = '私信通道待建立';
          break;
        case ResolvedPushStatus.channelBlocked:
          pushText = '私信通道已被关';
          break;
        case ResolvedPushStatus.disabled:
          pushText = '远程推送关闭';
          break;
        case ResolvedPushStatus.diagnosticsUnavailable:
          pushText = '暂时无法读取推送状态';
          break;
      }
    }

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
    if (!snapshot.diagnosticsAvailable) {
      issues++;
    }
    if (!snapshot.notificationsEnabled) {
      issues++;
    }
    if (snapshot.registrationId == null || snapshot.registrationId!.isEmpty) {
      issues++;
    }
    if (!snapshot.privateChannelExists) {
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
          '退出后会清理当前运行中的教务会话，但保留本机安全凭据和教务资料。',
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

    final eduProvider = context.read<EduProvider>();
    final courseProvider = context.read<CourseScheduleProvider>();

    await context.read<AcademicSessionController>().resetSession();
    eduProvider.clearMemoryForAccountTransition();
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
        // 1. 顶部账号摘要
        const SettingsAccountHeader(),

        // 常用设置 (多彩图标 + 效果图开源配色)
        SettingsSection(
          title: '常用设置',
          children: [
            SettingsTile(
              icon: Icons.wb_sunny_outlined,
              iconBgColor:
                  isDark ? const Color(0xFF1B3B36) : const Color(0xFFE4F4F0),
              iconColor:
                  isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72),
              title: '外观与显示',
              subtitle: _getAppearanceSummary(themeProvider),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AppearanceSettingsScreen(),
                  ),
                );
              },
            ),
            SettingsTile(
              icon: Icons.notifications_none_rounded,
              iconBgColor:
                  isDark ? const Color(0xFF1A334E) : const Color(0xFFE6F0FA),
              iconColor:
                  isDark ? const Color(0xFF82B1FF) : const Color(0xFF2A72D4),
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

        // 账号与隐私 (多彩图标 + 效果图开源配色)
        SettingsSection(
          title: '账号与隐私',
          children: [
            SettingsTile(
              icon: Icons.shield_outlined,
              iconBgColor:
                  isDark ? const Color(0xFF1B382B) : const Color(0xFFE6F5EE),
              iconColor:
                  isDark ? const Color(0xFF81C784) : const Color(0xFF1E8256),
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
              iconBgColor:
                  isDark ? const Color(0xFF1B3B36) : const Color(0xFFE4F4F0),
              iconColor:
                  isDark ? const Color(0xFF7ED6C5) : const Color(0xFF0D7B74),
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
            SettingsTile(
              icon: Icons.school_outlined,
              title: '本机教务',
              subtitle: '安全保存教务凭据、课表和成绩的独立设置',
              onTap: isLoggedIn
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AcademicDataSettingsScreen(),
                        ),
                      );
                    }
                  : null,
              enabled: isLoggedIn,
            ),
          ],
        ),

        // 支持与其他 (多彩图标 + 效果图开源配色)
        SettingsSection(
          title: '支持与其他',
          children: [
            SettingsTile(
              icon: Icons.build_outlined,
              iconBgColor:
                  isDark ? const Color(0xFF3D2A1A) : const Color(0xFFFDF0E6),
              iconColor:
                  isDark ? const Color(0xFFFFB74D) : const Color(0xFFE07A2B),
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
              iconBgColor:
                  isDark ? const Color(0xFF1A334E) : const Color(0xFFE6F0FA),
              iconColor:
                  isDark ? const Color(0xFF82B1FF) : const Color(0xFF2A72D4),
              title: '关于沈理校园',
              subtitle: '版本、检查更新与开源信息',
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

        // 退出登录按钮卡片
        if (isLoggedIn) ...[
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: CampusTheme.red.withValues(alpha: 0.3),
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _handleLogout(context, authProvider),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
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
