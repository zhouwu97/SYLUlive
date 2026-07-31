import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/diagnostic_log_entry.dart';
import '../../platform/platform_capabilities.dart';
import '../../providers/auth_provider.dart';
import '../../services/diagnostic_log_service.dart';
import '../../services/push_settings_service.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_status_badge.dart';
import '../../widgets/settings/settings_tile.dart';
import '../diagnostic_log_screen.dart';
import '../feedback_screen.dart';
import '../login_screen.dart';
import 'notification_background_settings_screen.dart';

class _PushDiagnosticInfo {
  final bool supportsJPush;
  final bool optedIn;
  final String? registrationId;
  final bool notificationsEnabled;
  final bool privateMessageChannelExists;
  final int privateMessageChannelImportance;
  final bool privateMessageChannelBlocked;
  final String? storedAlias;
  final String? storedAliasState;
  final String? aliasLastStatus;
  final String? aliasLastTime;
  final String? aliasLastDetail;
  final String? error;

  const _PushDiagnosticInfo({
    required this.supportsJPush,
    required this.optedIn,
    this.registrationId,
    required this.notificationsEnabled,
    required this.privateMessageChannelExists,
    required this.privateMessageChannelImportance,
    required this.privateMessageChannelBlocked,
    this.storedAlias,
    this.storedAliasState,
    this.aliasLastStatus,
    this.aliasLastTime,
    this.aliasLastDetail,
    this.error,
  });
}

/// 诊断与反馈二级页
class DiagnosticsSettingsScreen extends StatefulWidget {
  const DiagnosticsSettingsScreen({super.key});

  @override
  State<DiagnosticsSettingsScreen> createState() =>
      _DiagnosticsSettingsScreenState();
}

class _DiagnosticsSettingsScreenState extends State<DiagnosticsSettingsScreen> {
  static const _pushDiagChannel = MethodChannel(
    'shenliyuan/private_message_notifications',
  );

  _PushDiagnosticInfo? _info;
  bool _loading = true;
  bool _repairingPush = false;

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final info = await _gatherPushDiagnostics();
    if (!mounted) return;
    setState(() {
      _info = info;
      _loading = false;
    });
  }

  Future<_PushDiagnosticInfo> _gatherPushDiagnostics() async {
    final supportsJPush = PlatformCapabilities.current.supportsJPush;
    final optedIn = await PushSettingsService.isEnabled();

    Map<String, dynamic> native = {};
    List<DiagnosticLogEntry> logs = [];
    final errors = <String>[];

    if (supportsJPush) {
      try {
        final result = await _pushDiagChannel
            .invokeMapMethod<String, dynamic>('getPushDiagnostics');
        native = result ?? {};
      } catch (e) {
        errors.add('原生诊断读取失败: $e');
      }
    }

    try {
      logs = await DiagnosticLogService.instance.getLogs();
    } catch (e) {
      errors.add('日志读取失败: $e');
    }

    String? aliasLastStatus;
    String? aliasLastTime;
    String? aliasLastDetail;
    for (final log in logs) {
      if (log.source != '推送') continue;
      if (log.type == 'Alias 绑定成功' || log.type == 'Alias 恢复成功') {
        aliasLastStatus = '成功';
        final effectiveTime =
            log.lastSeenAt > 0 ? log.lastSeenAt : log.timestamp;
        aliasLastTime = DateFormat(
          'MM-dd HH:mm:ss',
        ).format(DateTime.fromMillisecondsSinceEpoch(effectiveTime));
        aliasLastDetail = log.detail.isNotEmpty ? log.detail : null;
        break;
      }
      if (log.type == 'Alias 绑定失败' || log.type == 'Alias 恢复失败') {
        aliasLastStatus = '失败';
        final effectiveTime =
            log.lastSeenAt > 0 ? log.lastSeenAt : log.timestamp;
        aliasLastTime = DateFormat(
          'MM-dd HH:mm:ss',
        ).format(DateTime.fromMillisecondsSinceEpoch(effectiveTime));
        aliasLastDetail = log.detail.isNotEmpty ? log.detail : null;
        break;
      }
    }

    final storedAliasState = native['storedAliasState']?.toString();
    if (storedAliasState == 'active') {
      if (aliasLastStatus != '成功') {
        aliasLastTime = null;
        aliasLastDetail = null;
      }
      aliasLastStatus = '成功';
    } else if (storedAliasState == 'pending_bind' && aliasLastStatus == null) {
      aliasLastStatus = '待绑定';
    }

    return _PushDiagnosticInfo(
      supportsJPush: supportsJPush,
      optedIn: optedIn,
      registrationId: native['registrationId']?.toString(),
      notificationsEnabled: native['notificationsEnabled'] == true,
      privateMessageChannelExists:
          native['privateMessageChannelExists'] == true,
      privateMessageChannelImportance:
          (native['privateMessageChannelImportance'] as num?)?.toInt() ?? -1,
      privateMessageChannelBlocked:
          native['privateMessageChannelBlocked'] == true,
      storedAlias: native['storedAlias']?.toString(),
      storedAliasState: storedAliasState,
      aliasLastStatus: aliasLastStatus,
      aliasLastTime: aliasLastTime,
      aliasLastDetail: aliasLastDetail,
      error: errors.isNotEmpty ? errors.join('\n') : null,
    );
  }

  String _maskValue(String? value, int visibleLength) {
    if (value == null || value.isEmpty) return '未获取';
    if (value.length <= visibleLength) return '***';
    return '***${value.substring(value.length - visibleLength)}';
  }

  String _importanceLabel(int importance) {
    switch (importance) {
      case 0:
        return '无 (IMPORTANCE_NONE)';
      case 1:
        return '最低 (IMPORTANCE_MIN)';
      case 2:
        return '低 (IMPORTANCE_LOW)';
      case 3:
        return '默认 (IMPORTANCE_DEFAULT)';
      case 4:
        return '高 (IMPORTANCE_HIGH)';
      case 5:
        return '最高 (IMPORTANCE_MAX)';
      default:
        return '未知 ($importance)';
    }
  }

  List<String> _calculateIssues(_PushDiagnosticInfo info) {
    if (!info.supportsJPush || !info.optedIn) {
      return <String>[];
    }
    if (info.error != null && info.error!.contains('原生诊断读取失败')) {
      return <String>['暂时无法读取原生推送状态'];
    }

    final issues = <String>[];
    if (info.registrationId == null || info.registrationId!.isEmpty) {
      issues.add('未获取到设备 RegistrationID');
    }
    if (!info.notificationsEnabled) {
      issues.add('系统通知总开关已关闭');
    }
    if (!info.privateMessageChannelExists) {
      issues.add('私信通知渠道未建立');
    }
    if (info.privateMessageChannelBlocked) {
      issues.add('私信通知渠道已被单独屏蔽');
    }
    if (info.aliasLastStatus == '失败' ||
        info.storedAliasState == 'pending_bind') {
      issues.add('设备 Alias 处于待绑定或失败状态');
    }
    if (info.error != null && !info.error!.contains('原生诊断读取失败')) {
      issues.add('诊断过程出现异常');
    }
    return issues;
  }

  void _copyPushDiagnostics(_PushDiagnosticInfo info) {
    final sb = StringBuffer();
    sb.writeln('═══ 推送诊断 ═══');
    sb.writeln('平台支持极光推送: ${info.supportsJPush}');
    sb.writeln('用户主动开启推送: ${info.optedIn}');
    sb.writeln('RegistrationID: ${_maskValue(info.registrationId, 6)}');
    sb.writeln('通知总权限: ${info.notificationsEnabled ? "已开启" : "已关闭"}');
    sb.writeln('私信通知渠道存在: ${info.privateMessageChannelExists}');
    sb.writeln('私信通知渠道已关闭: ${info.privateMessageChannelBlocked}');
    sb.writeln(
      '渠道重要性: ${_importanceLabel(info.privateMessageChannelImportance)}',
    );
    final aliasLabel =
        info.storedAliasState == 'pending_bind' ? '本地待绑定 Alias' : '已存储 Alias';
    sb.writeln('$aliasLabel: ${_maskValue(info.storedAlias, 4)}');
    sb.writeln(
      'Alias 最近状态: ${info.aliasLastStatus ?? "无记录"}'
      '${info.aliasLastTime != null ? " (${info.aliasLastTime})" : ""}',
    );
    if (info.aliasLastDetail != null) {
      sb.writeln('Alias 最近详情: ${info.aliasLastDetail}');
    }
    if (info.error != null) {
      sb.writeln('诊断异常: ${info.error}');
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('诊断信息已复制到剪贴板（敏感 ID 已掩码）'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleRepairPush() async {
    if (_repairingPush) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录账号，再进行远程推送修复')),
      );
      return;
    }

    setState(() => _repairingPush = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final result = await PushSettingsService.enableAndRegister(auth);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(result.message)));
        await _loadDiagnostics();
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('修复处理遇到异常: $e')));
      }
    } finally {
      if (mounted) setState(() => _repairingPush = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final isLoggedIn = auth.isLoggedIn && auth.user != null;
    final info = _info;
    final issues = info != null ? _calculateIssues(info) : <String>[];
    final isUnsupported = info != null && !info.supportsJPush;
    final isOptedOut = info != null && info.supportsJPush && !info.optedIn;

    return SettingsPageScaffold(
      title: '诊断与反馈',
      onRefresh: _loadDiagnostics,
      children: [
        // 诊断结论卡片
        if (_loading)
          const SettingsSection(
            children: [
              SettingsTile(
                icon: Icons.sync_rounded,
                title: '正在读取诊断状态...',
                subtitle: '正在检查极光推送、通知权限与保活状态',
                showChevron: false,
              ),
            ],
          )
        else if (info != null) ...[
          SettingsSection(
            title: '诊断结论',
            children: [
              if (isUnsupported)
                const SettingsTile(
                  icon: Icons.info_outline_rounded,
                  iconColor: CampusTheme.subText,
                  title: '当前平台不支持远程推送',
                  subtitle: '课程和考试本地提醒仍可正常使用。仅 Android / iOS 移动端支持远程推送。',
                  trailing: SettingsStatusBadge(
                    label: '不支持',
                    type: SettingsStatusBadgeType.neutral,
                  ),
                  showChevron: false,
                )
              else if (isOptedOut)
                const SettingsTile(
                  icon: Icons.notifications_off_outlined,
                  iconColor: CampusTheme.subText,
                  title: '远程推送未启用',
                  subtitle: '你已主动关闭远程推送，这不是故障。可在通知与后台设置中开启。',
                  trailing: SettingsStatusBadge(
                    label: '未启用',
                    type: SettingsStatusBadgeType.neutral,
                  ),
                  showChevron: false,
                )
              else
                SettingsTile(
                  icon: issues.isEmpty
                      ? Icons.check_circle_outline_rounded
                      : Icons.warning_amber_rounded,
                  iconColor:
                      issues.isEmpty ? CampusTheme.green : CampusTheme.orange,
                  title:
                      issues.isEmpty ? '通知状态正常' : '发现 ${issues.length} 项需要处理',
                  subtitle:
                      issues.isEmpty ? '系统通知权限正常，推送通道连接顺畅' : issues.join('；'),
                  trailing: SettingsStatusBadge(
                    label: issues.isEmpty ? '正常' : '需处理 (${issues.length})',
                    type: issues.isEmpty
                        ? SettingsStatusBadgeType.success
                        : SettingsStatusBadgeType.warning,
                  ),
                  showChevron: false,
                ),
            ],
          ),

          // 快捷处理
          SettingsSection(
            title: '快捷处理',
            children: [
              if (isOptedOut)
                SettingsTile(
                  icon: Icons.notifications_active_outlined,
                  title: '前往通知与后台设置',
                  subtitle: '开启远程消息推送与相关通知权限',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const NotificationBackgroundSettingsScreen(),
                      ),
                    ).then((_) => _loadDiagnostics());
                  },
                )
              else ...[
                if (!info.notificationsEnabled ||
                    info.privateMessageChannelBlocked)
                  SettingsTile(
                    icon: Icons.settings_applications_outlined,
                    title: '前往系统通知设置',
                    subtitle: info.privateMessageChannelBlocked
                        ? '调整私信通知渠道的独立开关与重要度'
                        : '开启应用通知权限或解除私信渠道屏蔽',
                    onTap: () {
                      if (info.privateMessageChannelBlocked) {
                        PushSettingsService.openNotificationChannelSettings(
                          'private_message',
                        );
                      } else {
                        PushSettingsService.openAppNotificationSettings();
                      }
                    },
                  ),
                if (!isLoggedIn && info.optedIn)
                  SettingsTile(
                    icon: Icons.account_circle_outlined,
                    title: '登录账号以同步推送状态',
                    subtitle: '未登录状态下无法绑定极光 Alias 设备别名',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LoginScreen(),
                        ),
                      ).then((_) => _loadDiagnostics());
                    },
                  ),
                if (isLoggedIn && info.optedIn && issues.isNotEmpty)
                  SettingsTile(
                    icon: Icons.refresh_rounded,
                    title: _repairingPush ? '正在重新注册...' : '重新注册与重新绑定',
                    subtitle: '再次向极光推送登记当前设备与 Alias',
                    enabled: !_repairingPush,
                    onTap: _handleRepairPush,
                  ),
              ],
              SettingsTile(
                icon: Icons.autorenew_rounded,
                title: '刷新诊断数据',
                onTap: _loadDiagnostics,
              ),
            ],
          ),

          // 详细技术信息 (ExpansionTile)
          SettingsSection(
            title: '详细技术状态',
            children: [
              Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: ExpansionTile(
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1B3B36)
                          : const Color(0xFFE4F4F0),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.bug_report_outlined,
                      size: 22,
                      color: CampusTheme.primary,
                    ),
                  ),
                  title: const Text(
                    '极光推送技术诊断参数',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    '查看 RegistrationID、Alias 绑定日志与通道状态',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  childrenPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  children: [
                    _buildTechRow('平台支持极光推送', info.supportsJPush ? '是' : '否'),
                    _buildTechRow('用户主动开启', info.optedIn ? '是' : '否'),
                    _buildTechRow(
                      'RegistrationID',
                      _maskValue(info.registrationId, 6),
                    ),
                    _buildTechRow(
                      '通知总权限',
                      info.notificationsEnabled ? '已开启' : '已关闭 (建议前往设置开启)',
                    ),
                    _buildTechRow(
                      '私信通知渠道',
                      info.privateMessageChannelExists
                          ? (info.privateMessageChannelBlocked
                              ? '已被单独屏蔽'
                              : '正常')
                          : '未建立',
                    ),
                    _buildTechRow(
                      '渠道重要性',
                      _importanceLabel(info.privateMessageChannelImportance),
                    ),
                    _buildTechRow(
                      info.storedAliasState == 'pending_bind'
                          ? '待绑定 Alias'
                          : '已绑定 Alias',
                      _maskValue(info.storedAlias, 4),
                    ),
                    _buildTechRow(
                      'Alias 最近记录',
                      '${info.aliasLastStatus ?? "无记录"}'
                          '${info.aliasLastTime != null ? " (${info.aliasLastTime})" : ""}',
                    ),
                    if (info.aliasLastDetail != null)
                      _buildTechRow('Alias 绑定详情', info.aliasLastDetail!),
                    if (info.error != null)
                      _buildTechRow('诊断异常', info.error!, isWarning: true),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => _copyPushDiagnostics(info),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('复制推送诊断文本'),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ],

        // 日志与反馈入口
        SettingsSection(
          title: '日志与反馈',
          children: [
            SettingsTile(
              icon: Icons.history_rounded,
              iconBgColor:
                  isDark ? const Color(0xFF1A334E) : const Color(0xFFE6F0FA),
              iconColor:
                  isDark ? const Color(0xFF82B1FF) : const Color(0xFF2A72D4),
              title: '运行诊断日志',
              subtitle: '查看网络请求、推送事件与异常抓取记录',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DiagnosticLogScreen(),
                  ),
                );
              },
            ),
            SettingsTile(
              icon: Icons.feedback_outlined,
              iconBgColor:
                  isDark ? const Color(0xFF3D2A1A) : const Color(0xFFFDF0E6),
              iconColor:
                  isDark ? const Color(0xFFFFB74D) : const Color(0xFFE07A2B),
              title: '问题与建议反馈',
              subtitle: '在线提交页面异常、功能建议或改进想法',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const FeedbackScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTechRow(String label, String value, {bool isWarning = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: isDark ? Colors.white60 : CampusTheme.subText,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isWarning
                    ? CampusTheme.red
                    : (isDark ? Colors.white : CampusTheme.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
