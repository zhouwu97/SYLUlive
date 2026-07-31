import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/diagnostic_log_entry.dart';
import '../../providers/auth_provider.dart';
import '../../services/diagnostic_log_service.dart';
import '../../services/keep_alive_service.dart';
import '../../services/push_settings_service.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_status_badge.dart';
import '../../widgets/settings/settings_tile.dart';
import '../diagnostic_log_screen.dart';
import '../feedback_screen.dart';

class _PushDiagnosticInfo {
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

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    setState(() => _loading = true);
    final info = await _gatherPushDiagnostics();
    if (mounted) {
      setState(() {
        _info = info;
        _loading = false;
      });
    }
  }

  Future<_PushDiagnosticInfo> _gatherPushDiagnostics() async {
    Map<String, dynamic> native = {};
    List<DiagnosticLogEntry> logs = [];
    final errors = <String>[];

    try {
      final result = await _pushDiagChannel
          .invokeMapMethod<String, dynamic>('getPushDiagnostics');
      native = result ?? {};
    } catch (e) {
      errors.add('原生诊断读取失败: $e');
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
    if (info.error != null) {
      issues.add('诊断过程出现异常');
    }
    return issues;
  }

  void _copyPushDiagnostics(_PushDiagnosticInfo info) {
    final sb = StringBuffer();
    sb.writeln('═══ 推送诊断 ═══');
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final info = _info;
    final issues = info != null ? _calculateIssues(info) : <String>[];

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
              SettingsTile(
                icon: issues.isEmpty
                    ? Icons.check_circle_outline_rounded
                    : Icons.warning_amber_rounded,
                iconColor:
                    issues.isEmpty ? CampusTheme.green : CampusTheme.orange,
                title: issues.isEmpty ? '通知状态正常' : '发现 ${issues.length} 项需要处理',
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
          if (issues.isNotEmpty)
            SettingsSection(
              title: '快捷处理',
              children: [
                if (!info.notificationsEnabled ||
                    info.privateMessageChannelBlocked)
                  SettingsTile(
                    icon: Icons.settings_applications_outlined,
                    title: '前往系统通知设置',
                    subtitle: '开启通知权限或解除私信渠道屏蔽',
                    onTap: () => KeepAliveService.instance.openSettings(),
                  ),
                SettingsTile(
                  icon: Icons.refresh_rounded,
                  title: '重新注册与重新绑定',
                  subtitle: '再次向极光推送登记当前设备与 Alias',
                  onTap: () async {
                    final auth = context.read<AuthProvider>();
                    await PushSettingsService.enableAndRegister(auth);
                    await _loadDiagnostics();
                  },
                ),
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
                          ? const Color(0xFF7ED6C5).withValues(alpha: 0.15)
                          : CampusTheme.primaryLight,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.code_rounded,
                      size: 22,
                      color: CampusTheme.primary,
                    ),
                  ),
                  title: Text(
                    '查看详细诊断信息',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : CampusTheme.text,
                    ),
                  ),
                  subtitle: Text(
                    '包含 RegistrationID、渠道重要性与绑定日志（已掩码）',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: isDark ? Colors.white60 : CampusTheme.subText,
                    ),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildDetailRow(
                            'RegistrationID',
                            _maskValue(info.registrationId, 6),
                            isDark,
                          ),
                          _buildDetailRow(
                            '系统通知权限',
                            info.notificationsEnabled ? '已开启' : '已关闭',
                            isDark,
                            isOk: info.notificationsEnabled,
                          ),
                          _buildDetailRow(
                            '私信通知渠道存在',
                            info.privateMessageChannelExists ? '是' : '否',
                            isDark,
                            isOk: info.privateMessageChannelExists,
                          ),
                          _buildDetailRow(
                            '私信通知渠道屏蔽',
                            info.privateMessageChannelBlocked ? '已被屏蔽' : '正常开启',
                            isDark,
                            isOk: !info.privateMessageChannelBlocked,
                          ),
                          _buildDetailRow(
                            '渠道重要性',
                            _importanceLabel(
                                info.privateMessageChannelImportance),
                            isDark,
                          ),
                          _buildDetailRow(
                            '本地 Alias',
                            _maskValue(info.storedAlias, 4),
                            isDark,
                          ),
                          _buildDetailRow(
                            'Alias 最近状态',
                            '${info.aliasLastStatus ?? "无记录"}${info.aliasLastTime != null ? " (${info.aliasLastTime})" : ""}',
                            isDark,
                          ),
                          if (info.error != null)
                            _buildDetailRow(
                              '异常记录',
                              info.error!,
                              isDark,
                              isOk: false,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],

        // 反馈与日志
        SettingsSection(
          title: '反馈与日志',
          children: [
            SettingsTile(
              icon: Icons.receipt_long_outlined,
              title: '运行日志',
              subtitle: '查看保活、推送和异常详细记录',
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
              title: '功能建议与问题反馈',
              subtitle: '提交使用问题或改进建议',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const FeedbackScreen(),
                  ),
                );
              },
            ),
            if (info != null)
              SettingsTile(
                icon: Icons.copy_rounded,
                title: '复制诊断信息',
                subtitle: '复制已掩码的技术诊断文本',
                onTap: () => _copyPushDiagnostics(info),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDetailRow(
    String label,
    String value,
    bool isDark, {
    bool? isOk,
  }) {
    Color valueColor = isDark ? Colors.white70 : CampusTheme.text;
    if (isOk == true) valueColor = CampusTheme.green;
    if (isOk == false) valueColor = CampusTheme.red;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: isDark ? Colors.white54 : CampusTheme.subText,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
