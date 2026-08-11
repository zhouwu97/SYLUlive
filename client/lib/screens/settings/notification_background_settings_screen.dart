import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/platform_capabilities.dart';
import '../../providers/auth_provider.dart';
import '../../services/keep_alive_service.dart';
import '../../services/push_settings_service.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_status_badge.dart';
import '../../widgets/settings/settings_switch.dart';
import '../../widgets/settings/settings_tile.dart';

enum RemotePushUiStatus {
  disabled,
  loading,
  ready,
  permissionDenied,
  registrationFailed,
  configuring,
  channelUnavailable,
  channelBlocked,
  diagnosticsUnavailable,
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

    final snapshot = await PushSettingsService.getPushSnapshot();
    final resolved = resolveRemotePushStatus(snapshot);

    RemotePushUiStatus status;
    switch (resolved) {
      case ResolvedPushStatus.disabled:
        status = RemotePushUiStatus.disabled;
        break;
      case ResolvedPushStatus.permissionDenied:
        status = RemotePushUiStatus.permissionDenied;
        break;
      case ResolvedPushStatus.registrationFailed:
        status = RemotePushUiStatus.registrationFailed;
        break;
      case ResolvedPushStatus.configuring:
        status = RemotePushUiStatus.configuring;
        break;
      case ResolvedPushStatus.channelUnavailable:
        status = RemotePushUiStatus.channelUnavailable;
        break;
      case ResolvedPushStatus.channelBlocked:
        status = RemotePushUiStatus.channelBlocked;
        break;
      case ResolvedPushStatus.diagnosticsUnavailable:
        status = RemotePushUiStatus.diagnosticsUnavailable;
        break;
      case ResolvedPushStatus.ready:
        status = RemotePushUiStatus.ready;
        break;
    }

    if (!mounted) return;
    setState(() {
      _pushStatus = status;
    });
  }

  Future<void> _handlePushToggle(bool enabled) async {
    if (_pushStatus == RemotePushUiStatus.loading) return;

    final previousStatus = _pushStatus;
    setState(() {
      _pushStatus = RemotePushUiStatus.loading;
      _pushErrorMessage = null;
    });

    final auth = context.read<AuthProvider>();

    if (enabled) {
      final result = await PushSettingsService.enableAndRegister(auth);
      if (!mounted) return;
      AppFeedback.info(result.message, context: context);
      await _loadPushState();
      return;
    }

    final result = await PushSettingsService.disable(auth);
    if (!mounted) return;

    if (!result.success) {
      setState(() => _pushStatus = previousStatus);
      AppFeedback.error(
        result.errorMessage ?? '关闭远程推送失败',
        context: context,
      );
      return;
    }

    AppFeedback.success(
      '已关闭远程推送，课程和考试提醒不受影响',
      context: context,
    );
    await _loadPushState();
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
    final status =
        await KeepAliveService.instance.setHideRecentsEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _keepAliveStatus = status;
      _hideRecentsBusy = false;
    });
  }

  Future<void> _showKeepAliveGuideDialog() async {
    final dialogTheme = CampusTheme.withBrandAccent(Theme.of(context));
    await showDialog<void>(
      context: context,
      builder: (ctx) => Theme(
        data: dialogTheme,
        child: AlertDialog(
          title: const Text('后台保活推荐设置'),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '为了保证私信接收和后台通知即时送达，建议在系统设置中完成以下配置：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12),
                Text('1. 电池优化：设置为“不限制”或“无限制”；'),
                SizedBox(height: 6),
                Text('2. 自启动管理：开启“允许自启动”；'),
                SizedBox(height: 6),
                Text('3. 最近任务锁定：在多任务界面给本应用加锁。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                KeepAliveService.instance.openSettings();
              },
              child: const Text('前往系统设置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPushStatusBadge() {
    switch (_pushStatus) {
      case RemotePushUiStatus.loading:
        return const SettingsStatusBadge(
          label: '检查中',
          type: SettingsStatusBadgeType.neutral,
        );
      case RemotePushUiStatus.ready:
        return const SettingsStatusBadge(
          label: '已开启',
          type: SettingsStatusBadgeType.success,
        );
      case RemotePushUiStatus.permissionDenied:
        return const SettingsStatusBadge(
          label: '权限受限',
          type: SettingsStatusBadgeType.warning,
        );
      case RemotePushUiStatus.registrationFailed:
        return const SettingsStatusBadge(
          label: '注册失败',
          type: SettingsStatusBadgeType.warning,
        );
      case RemotePushUiStatus.configuring:
        return const SettingsStatusBadge(
          label: '待绑定',
          type: SettingsStatusBadgeType.warning,
        );
      case RemotePushUiStatus.channelUnavailable:
        return const SettingsStatusBadge(
          label: '渠道待建立',
          type: SettingsStatusBadgeType.warning,
        );
      case RemotePushUiStatus.channelBlocked:
        return const SettingsStatusBadge(
          label: '渠道已屏蔽',
          type: SettingsStatusBadgeType.warning,
        );
      case RemotePushUiStatus.diagnosticsUnavailable:
        return const SettingsStatusBadge(
          label: '诊断受阻',
          type: SettingsStatusBadgeType.warning,
        );
      case RemotePushUiStatus.disabled:
        return const SettingsStatusBadge(
          label: '未开启',
          type: SettingsStatusBadgeType.neutral,
        );
    }
  }

  String _buildPushSubtitle() {
    switch (_pushStatus) {
      case RemotePushUiStatus.loading:
        return '正在读取极光推送与通道注册状态...';
      case RemotePushUiStatus.ready:
        return '已建立极光注册与私信推送通道';
      case RemotePushUiStatus.permissionDenied:
        return '极光推送已开启，但系统通知权限已被禁用';
      case RemotePushUiStatus.registrationFailed:
        return _pushErrorMessage ?? '向极光服务端注册设备失败，请稍后重试';
      case RemotePushUiStatus.configuring:
        return '设备已注册，当前 Alias 处于待绑定状态';
      case RemotePushUiStatus.channelUnavailable:
        return '设备已注册，私信通知渠道尚未建立';
      case RemotePushUiStatus.channelBlocked:
        return '设备已注册，但私信通知渠道已被系统设置单独屏蔽';
      case RemotePushUiStatus.diagnosticsUnavailable:
        return '暂时无法读取原生推送状态，请刷新重试';
      case RemotePushUiStatus.disabled:
        return '仅接收本地提醒；远程私信通知已暂停';
    }
  }

  @override
  Widget build(BuildContext context) {
    final supportsJPush = PlatformCapabilities.current.supportsJPush;
    final isPushActive = _pushStatus == RemotePushUiStatus.ready ||
        _pushStatus == RemotePushUiStatus.permissionDenied ||
        _pushStatus == RemotePushUiStatus.registrationFailed ||
        _pushStatus == RemotePushUiStatus.configuring ||
        _pushStatus == RemotePushUiStatus.channelUnavailable ||
        _pushStatus == RemotePushUiStatus.channelBlocked;

    return SettingsPageScaffold(
      title: '通知与后台',
      onRefresh: () async {
        await _loadKeepAliveStatus();
        await _loadPushState();
      },
      children: [
        // 远程推送
        SettingsSection(
          title: '远程消息推送',
          children: [
            if (!supportsJPush)
              const SettingsTile(
                icon: Icons.notifications_off_outlined,
                iconColor: CampusTheme.subText,
                title: '远程推送',
                subtitle: '当前平台不支持极光远程推送（仅移动端 App 支持）',
                trailing: SettingsStatusBadge(
                  label: '不支持',
                  type: SettingsStatusBadgeType.neutral,
                ),
                showChevron: false,
              )
            else
              SettingsTile(
                icon: Icons.notifications_outlined,
                iconColor:
                    isPushActive ? CampusTheme.primary : CampusTheme.subText,
                title: '远程消息推送',
                subtitle: _buildPushSubtitle(),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildPushStatusBadge(),
                    const SizedBox(width: 8),
                    SettingsSwitch(
                      value: isPushActive,
                      onChanged: _pushStatus == RemotePushUiStatus.loading
                          ? null
                          : _handlePushToggle,
                    ),
                  ],
                ),
              ),
          ],
        ),

        // 智能课表与成绩提醒
        const SettingsSection(
          title: '本地消息提醒',
          children: [
            SettingsTile(
              icon: Icons.event_available_outlined,
              iconColor: CampusTheme.green,
              title: '本地课程与考试提醒',
              subtitle: '基于应用本地常驻任务生成，不受远程推送开关影响',
              trailing: SettingsStatusBadge(
                label: '始终有效',
                type: SettingsStatusBadgeType.success,
              ),
              showChevron: false,
            ),
          ],
        ),

        // 后台保活服务 (Android 专用)
        if (_keepAliveStatus.supported)
          SettingsSection(
            title: '后台保活服务 (Android)',
            children: [
              SettingsTile(
                icon: Icons.bolt_outlined,
                iconColor: _keepAliveStatus.enabled
                    ? CampusTheme.primary
                    : CampusTheme.subText,
                title: '开启前台保活服务',
                subtitle: _keepAliveStatus.serviceRunning
                    ? '前台服务正在运行中'
                    : (_keepAliveStatus.enabled
                        ? '服务已开启，等待系统拉起'
                        : '关闭后可能导致私信推送延迟'),
                trailing: SettingsSwitch(
                  value: _keepAliveStatus.enabled,
                  onChanged: _keepAliveBusy ? null : _setKeepAliveEnabled,
                ),
              ),
              SettingsTile(
                icon: Icons.visibility_off_outlined,
                title: '从最近任务隐藏',
                subtitle: '在多任务截图中隐藏本应用卡片',
                trailing: SettingsSwitch(
                  value: _keepAliveStatus.hideRecentsEnabled,
                  onChanged: _hideRecentsBusy ? null : _setHideRecentsEnabled,
                ),
              ),
              SettingsTile(
                icon: Icons.settings_applications_outlined,
                title: '系统保活指南',
                subtitle: '包含电池无限制设置、允许自启动等提示',
                onTap: _showKeepAliveGuideDialog,
              ),
            ],
          ),
      ],
    );
  }
}
