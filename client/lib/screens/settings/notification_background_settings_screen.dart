import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/platform_capabilities.dart';
import '../../providers/auth_provider.dart';
import '../../services/keep_alive_service.dart';
import '../../services/push_settings_service.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_status_badge.dart';
import '../../widgets/settings/settings_tile.dart';

enum RemotePushUiStatus {
  disabled,
  loading,
  ready,
  permissionDenied,
  registrationFailed,
}

/// 通知与后台设置二级页
class NotificationBackgroundSettingsScreen extends StatefulWidget {
  const NotificationBackgroundSettingsScreen({super.key});

  @override
  State<NotificationBackgroundSettingsScreen> createState() =>
      _NotificationBackgroundSettingsScreenState();
}

class _NotificationBackgroundSettingsScreenState
    extends State<NotificationBackgroundSettingsScreen> {
  KeepAliveStatus _keepAliveStatus = const KeepAliveStatus.unsupported();
  bool _keepAliveBusy = false;
  bool _hideRecentsBusy = false;

  RemotePushUiStatus _pushStatus = RemotePushUiStatus.loading;
  String? _pushErrorMessage;

  @override
  void initState() {
    super.initState();
    _loadKeepAliveStatus();
    _loadPushState();
  }

  Future<void> _loadPushState() async {
    if (!PlatformCapabilities.current.supportsJPush) {
      if (mounted) {
        setState(() {
          _pushStatus = RemotePushUiStatus.disabled;
        });
      }
      return;
    }

    final enabled = await PushSettingsService.isEnabled();
    if (!mounted) return;
    setState(() {
      _pushStatus =
          enabled ? RemotePushUiStatus.ready : RemotePushUiStatus.disabled;
    });
  }

  Future<void> _handlePushToggle(bool enabled) async {
    if (_pushStatus == RemotePushUiStatus.loading) return;

    setState(() {
      _pushStatus = RemotePushUiStatus.loading;
      _pushErrorMessage = null;
    });

    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);

    if (enabled) {
      final result = await PushSettingsService.enableAndRegister(auth);
      if (!mounted) return;

      if (result.registrationSucceeded && result.permissionGranted) {
        setState(() => _pushStatus = RemotePushUiStatus.ready);
        messenger.showSnackBar(SnackBar(content: Text(result.message)));
      } else if (result.registrationSucceeded && !result.permissionGranted) {
        setState(() => _pushStatus = RemotePushUiStatus.permissionDenied);
        messenger.showSnackBar(
          const SnackBar(content: Text('已注册极光推送，但系统通知权限已被禁用')),
        );
      } else {
        setState(() {
          _pushStatus = RemotePushUiStatus.registrationFailed;
          _pushErrorMessage = result.message;
        });
        messenger.showSnackBar(SnackBar(content: Text(result.message)));
      }
      return;
    }

    final result = await PushSettingsService.disable(auth);
    if (!mounted) return;

    if (!result.success) {
      setState(() => _pushStatus = RemotePushUiStatus.ready);
      messenger.showSnackBar(
        SnackBar(content: Text(result.errorMessage ?? '关闭远程推送失败')),
      );
      return;
    }

    setState(() => _pushStatus = RemotePushUiStatus.disabled);
    messenger.showSnackBar(
      const SnackBar(content: Text('已关闭远程推送，课程和考试提醒不受影响')),
    );
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

    if (enabled) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('隐藏最近任务（实验功能）'),
          content: const Text(
            '开启后仅从系统最近任务列表中隐藏，并不等同于后台保活。\n'
            '部分设备重新打开应用时可能需要重新加载界面。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('理解并开启'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

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

  String _keepAliveSubtitle() {
    if (!_keepAliveStatus.supported) return '当前平台不支持后台服务';
    if (!_keepAliveStatus.enabled) return '开启后按提示加入后台白名单，提升提醒稳定性';
    if (_keepAliveStatus.serviceRunning) {
      return _keepAliveStatus.isIgnoringBatteryOptimizations
          ? '运行中，后台提醒更稳定'
          : '运行中，请允许自启动和后台无限制';
    }
    return '已开启，等待系统启动保活服务';
  }

  @override
  Widget build(BuildContext context) {
    final supportsJPush = PlatformCapabilities.current.supportsJPush;

    SettingsStatusBadge pushBadge;
    switch (_pushStatus) {
      case RemotePushUiStatus.ready:
        pushBadge = const SettingsStatusBadge(
          label: '远程推送已开启',
          type: SettingsStatusBadgeType.success,
        );
        break;
      case RemotePushUiStatus.permissionDenied:
        pushBadge = const SettingsStatusBadge(
          label: '权限受限',
          type: SettingsStatusBadgeType.warning,
        );
        break;
      case RemotePushUiStatus.registrationFailed:
        pushBadge = const SettingsStatusBadge(
          label: '需要重试',
          type: SettingsStatusBadgeType.danger,
        );
        break;
      case RemotePushUiStatus.loading:
        pushBadge = const SettingsStatusBadge(
          label: '加载中...',
          type: SettingsStatusBadgeType.neutral,
        );
        break;
      case RemotePushUiStatus.disabled:
        pushBadge = const SettingsStatusBadge(
          label: '推送未开启',
          type: SettingsStatusBadgeType.neutral,
        );
        break;
    }

    SettingsStatusBadge keepAliveBadge;
    if (!_keepAliveStatus.supported) {
      keepAliveBadge = const SettingsStatusBadge(
        label: '不支持',
        type: SettingsStatusBadgeType.neutral,
      );
    } else if (_keepAliveStatus.serviceRunning) {
      keepAliveBadge = const SettingsStatusBadge(
        label: '运行中',
        type: SettingsStatusBadgeType.success,
      );
    } else if (_keepAliveStatus.enabled) {
      keepAliveBadge = const SettingsStatusBadge(
        label: '已开启待启动',
        type: SettingsStatusBadgeType.info,
      );
    } else {
      keepAliveBadge = const SettingsStatusBadge(
        label: '未开启',
        type: SettingsStatusBadgeType.neutral,
      );
    }

    return SettingsPageScaffold(
      title: '通知与后台',
      onRefresh: () async {
        await _loadKeepAliveStatus();
        await _loadPushState();
      },
      children: [
        // 状态概览
        SettingsSection(
          title: '状态概览',
          children: [
            SettingsTile(
              icon: Icons.notifications_active_outlined,
              title: '远程消息推送',
              subtitle: supportsJPush ? '接收校内重要推文与关注通知' : '当前平台不支持极光推送',
              trailing: pushBadge,
            ),
            SettingsTile(
              icon: Icons.run_circle_outlined,
              title: '后台保活服务',
              subtitle: _keepAliveSubtitle(),
              trailing: keepAliveBadge,
            ),
          ],
        ),

        // 远程消息
        if (supportsJPush)
          SettingsSection(
            title: '远程消息',
            children: [
              SettingsTile(
                icon: Icons.notifications_none_rounded,
                title: '接收远程消息推送',
                subtitle: _pushStatus == RemotePushUiStatus.registrationFailed
                    ? (_pushErrorMessage ?? '注册失败，请检查网络后重试')
                    : '包含推文更新、活动发布与私信推送',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_pushStatus ==
                        RemotePushUiStatus.registrationFailed) ...[
                      TextButton(
                        onPressed: () => _handlePushToggle(true),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          foregroundColor: CampusTheme.orange,
                        ),
                        child: const Text('重试'),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Switch(
                      value: _pushStatus == RemotePushUiStatus.ready ||
                          _pushStatus == RemotePushUiStatus.permissionDenied ||
                          _pushStatus == RemotePushUiStatus.registrationFailed,
                      onChanged: _pushStatus == RemotePushUiStatus.loading
                          ? null
                          : _handlePushToggle,
                      activeThumbColor: CampusTheme.primary,
                    ),
                  ],
                ),
              ),
            ],
          ),

        // 本地提醒说明
        const SettingsSection(
          title: '本地提醒',
          children: [
            SettingsTile(
              icon: Icons.alarm_outlined,
              title: '课程与考试提醒说明',
              subtitle: '课程提醒与考试提醒主要由本机定时任务提供，不依赖远程消息推送，可在课表和考试页面分别设置。',
              showChevron: false,
            ),
          ],
        ),

        // 后台运行
        SettingsSection(
          title: '后台运行',
          children: [
            SettingsTile(
              icon: Icons.power_settings_new_rounded,
              title: '后台保活',
              subtitle: _keepAliveSubtitle(),
              trailing: Switch(
                value: _keepAliveStatus.supported && _keepAliveStatus.enabled,
                onChanged: !_keepAliveStatus.supported || _keepAliveBusy
                    ? null
                    : _setKeepAliveEnabled,
                activeThumbColor: CampusTheme.primary,
              ),
            ),
            if (_keepAliveStatus.supported)
              SettingsTile(
                icon: Icons.tune_rounded,
                title: '系统后台权限设置',
                subtitle: '电池无限制、允许自启动和后台活动白名单',
                onTap: () => KeepAliveService.instance.openSettings(),
              ),
          ],
        ),

        // 实验性功能
        if (_keepAliveStatus.supported)
          SettingsSection(
            title: '实验性功能',
            children: [
              SettingsTile(
                icon: Icons.layers_clear_outlined,
                title: '从最近任务中隐藏',
                subtitle: '只隐藏系统最近任务卡片，不等于后台保活；部分设备重新打开应用时可能重新加载页面。',
                trailing: Switch(
                  value: _keepAliveStatus.supported &&
                      _keepAliveStatus.hideRecentsEnabled,
                  onChanged: !_keepAliveStatus.supported || _hideRecentsBusy
                      ? null
                      : _setHideRecentsEnabled,
                  activeThumbColor: CampusTheme.primary,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
