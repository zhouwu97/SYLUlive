import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import '../widgets/required_legal_consent_dialog.dart';
import '../services/push_settings_service.dart';
import '../widgets/campus/campus_theme.dart';
import 'legal_documents_screen.dart';

class PrivacyCenterScreen extends StatefulWidget {
  final bool restricted;

  const PrivacyCenterScreen({super.key, this.restricted = false});

  @override
  State<PrivacyCenterScreen> createState() => _PrivacyCenterScreenState();
}

class _PrivacyCenterScreenState extends State<PrivacyCenterScreen> {
  List<Map<String, dynamic>> _requests = const [];
  bool _loadingRequests = true;
  bool _loadingData = false;
  bool _exporting = false;
  bool _revoking = false;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    try {
      final response = await context.read<AuthProvider>().dio.get('/user/privacy/requests');
      final items = response.data is Map ? response.data['items'] : null;
      if (mounted) {
        setState(() {
          _requests = items is List
              ? items.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList()
              : const [];
          _loadingRequests = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingRequests = false);
    }
  }



  Future<void> _showPersonalData() async {
    if (_loadingData) return;
    setState(() => _loadingData = true);
    try {
      final response = await context.read<AuthProvider>().dio.get('/user/privacy/data');
      if (response.data is! Map) throw const FormatException('个人信息响应无效');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _PersonalDataScreen(
            data: Map<String, dynamic>.from(response.data as Map),
          ),
        ),
      );
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } catch (_) {
      _showMessage('读取个人信息失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _exportData() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final response = await context.read<AuthProvider>().dio.get('/user/privacy/export');
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/shenliyuan-personal-data.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(response.data),
      );
      await Share.shareXFiles([XFile(file.path)], text: '我的个人信息导出文件');
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } catch (_) {
      _showMessage('导出失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _withdrawConsent() async {
    if (_revoking) return;
    var password = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销全部同意'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('撤销后，社区、教务、消息和其他依赖授权的功能将立即停止使用，已保存的教务凭证和推送标识会被清除。'),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('withdraw-consent-password'),
              obscureText: true,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: '输入 APP 密码确认'),
              onChanged: (value) => password = value,
              onSubmitted: (value) {
                if (value.isNotEmpty) Navigator.pop(dialogContext, true);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-withdraw-consent'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, password.isNotEmpty),
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || password.isEmpty || !mounted) return;

    setState(() => _revoking = true);
    final result = await context.read<AuthProvider>().withdrawLegalConsents(password);
    if (!mounted) return;
    setState(() => _revoking = false);
    if (!result.success) {
      _showMessage(result.errorMessage ?? '撤销同意失败');
      return;
    }
    await PushSettingsService.clearLocal();
    _showMessage('已撤销全部同意，相关功能已停止使用');
  }

  Future<void> _renewConsent() async {
    final auth = context.read<AuthProvider>();
    await showRequiredLegalConsentDialog(
      context,
      requiresEduDataConsent: auth.user?.eduAuthorized ?? false,
    );
  }

  Future<void> _showCancelAccountDialog() async {
    final passwordController = TextEditingController();
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('注销账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('注销不可恢复。账号身份资料、教务凭证和推送标识将被清除或匿名化；必要的内容关联与审计记录会按适用法律保留。'),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '输入 APP 密码确认'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      passwordController.dispose();
      return;
    }
    final result = await auth.deleteAccount(passwordController.text);
    passwordController.dispose();
    if (!mounted) return;
    if (!result.success) {
      _showMessage(result.errorMessage ?? '账号注销失败');
      return;
    }
    await PushSettingsService.clearLocal();
    if (!mounted) return;
    _showMessage('账号已注销');
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  String _errorMessage(DioException error) {
    final body = error.response?.data;
    if (body is Map) {
      final message = body['message'] ?? body['error'];
      if (message != null) return message.toString();
    }
    return '操作失败，请稍后重试';
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }


  Future<void> _showAuthorizationManagementSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? CampusTheme.darkBg : CampusTheme.bg;
    final auth = context.read<AuthProvider>();

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '授权管理',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  _PrivacyActionTile(
                    icon: Icons.school_outlined,
                    title: '教务数据',
                    subtitle: (auth.user?.eduAuthorized ?? false) ? '已授权' : '未授权',
                    trailing: const SizedBox.shrink(),
                  ),
                  _PrivacyActionTile(
                    icon: Icons.alarm_on_outlined,
                    title: '本地课程和考试提醒',
                    subtitle: '本地提醒不依赖远程推送，可在课表和考试功能中分别管理',
                    trailing: const SizedBox.shrink(),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _withdrawConsent();
                        },
                        child: const Text('撤销全部同意'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget get _loadingWidget {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF62CDBD) : CampusTheme.primary;
    return SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: accent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final restricted = widget.restricted || !(auth.user?.legalConsentsActive ?? true);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? CampusTheme.darkBg : CampusTheme.bg;
    final accent = isDark ? const Color(0xFF62CDBD) : CampusTheme.primary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: !widget.restricted,
        title: const Text('隐私与数据权利'),
        actions: [
          if (restricted)
            IconButton(
              tooltip: '退出登录',
              onPressed: auth.logout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        physics: const BouncingScrollPhysics(),
        children: [
          if (restricted) ...[
            _RestrictedNotice(),
            const SizedBox(height: 18),
          ],
          
          const _PrivacySectionTitle('协议与说明'),
          const SizedBox(height: 10),
          _PrivacySectionCard(
            children: [
              _PrivacyActionTile(
                icon: Icons.policy_outlined,
                title: '查看协议、隐私政策与第三方服务说明',
                subtitle: '包含教务数据专项授权和投诉举报规则',
                enabled: true,
                onTap: () => LegalDocumentsScreen.open(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          
          const _PrivacySectionTitle('你的数据'),
          const SizedBox(height: 10),
          _PrivacySectionCard(
            children: [
              _PrivacyActionTile(
                key: const ValueKey('access-personal-data'),
                icon: Icons.person_search_outlined,
                title: '查阅个人信息',
                subtitle: '直接查看账户资料、教务绑定和授权记录',
                trailing: _loadingData ? _loadingWidget : null,
                onTap: _loadingData ? null : _showPersonalData,
              ),
              const _PrivacyDivider(),
              _PrivacyActionTile(
                key: const ValueKey('export-personal-data'),
                icon: Icons.ios_share_outlined,
                title: '导出个人数据',
                subtitle: '生成可分享 JSON，不含认证凭证',
                trailing: _exporting ? _loadingWidget : null,
                onTap: _exporting ? null : _exportData,
              ),

            ],
          ),
          const SizedBox(height: 18),

          const _PrivacySectionTitle('授权管理'),
          const SizedBox(height: 10),
          if (restricted)
            _PrivacySectionCard(
              children: [
                _PrivacyActionTile(
                  key: const ValueKey('renew-legal-consents'),
                  icon: Icons.verified_user_outlined,
                  title: '重新授权',
                  subtitle: '重新确认最新协议后恢复正常使用',
                  onTap: _renewConsent,
                ),
              ],
            )
          else
            _PrivacySectionCard(
              children: [
                _PrivacyActionTile(
                  icon: Icons.tune_outlined,
                  title: '按功能管理授权',
                  subtitle: '教务绑定、远程推送和本地提醒分别管理',
                  onTap: _showAuthorizationManagementSheet,
                ),
              ],
            ),
          const SizedBox(height: 18),

          const _PrivacySectionTitle('账号管理'),
          const SizedBox(height: 10),
          _PrivacySectionCard(
            children: [
              _PrivacyActionTile(
                key: const ValueKey('cancel-account'),
                icon: Icons.delete_forever_outlined,
                title: '注销账号',
                subtitle: '清除或匿名化账号资料，此操作不可恢复',
                danger: true,
                onTap: _showCancelAccountDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RestrictedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: errorColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: errorColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block_outlined, size: 20, color: errorColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '授权已撤销',
                  style: TextStyle(fontWeight: FontWeight.w600, color: errorColor, fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(
                  '社区、教务、消息等依赖授权的功能已停止使用',
                  style: TextStyle(fontSize: 13, color: errorColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacySectionTitle extends StatelessWidget {
  final String text;

  const _PrivacySectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF62CDBD) : CampusTheme.primary;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Row(
      children: [
        Container(
          width: 4,
          height: 22,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: onSurface,
          ),
        ),
      ],
    );
  }
}

class _PrivacySectionCard extends StatelessWidget {
  final List<Widget> children;

  const _PrivacySectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? CampusTheme.darkCard : CampusTheme.card;
    final borderColor = isDark ? Colors.white.withValues(alpha: 0.08) : CampusTheme.softBorder;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.035),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _PrivacyDivider extends StatelessWidget {
  const _PrivacyDivider();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? Colors.white.withValues(alpha: 0.08) : CampusTheme.softBorder;

    return Divider(
      height: 1,
      thickness: 1,
      indent: 64,
      endIndent: 16,
      color: borderColor,
    );
  }
}

class _PrivacyActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  // ignore: unused_element_parameter
  final bool enabled;

  const _PrivacyActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF62CDBD) : CampusTheme.primary;
    final subText = isDark ? Theme.of(context).colorScheme.onSurfaceVariant : CampusTheme.subText;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final errorColor = Theme.of(context).colorScheme.error;

    final iconColor = danger ? errorColor : accent;

    return InkWell(
      onTap: enabled ? onTap : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 76),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(icon, size: 27, color: iconColor),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: subText,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else if (onTap != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, size: 22, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonalDataScreen extends StatefulWidget {
  final Map<String, dynamic> data;

  const _PersonalDataScreen({required this.data});

  @override
  State<_PersonalDataScreen> createState() => _PersonalDataScreenState();
}

class _PersonalDataScreenState extends State<_PersonalDataScreen> {
  bool _saving = false;

  static const _accountLabels = <String, String>{
    'id': '用户 ID',
    'student_id': '登录账号',
    'nickname': '昵称',
    'gender': '性别',
    'avatar_set': '头像',
    'background_set': '背景图',
    'qq': 'QQ',
    'created_at': '注册时间',
    'edu_bound': '教务绑定',
    'edu_student_id': '教务学号',
    'edu_grade': '年级',
    'edu_college': '学院',
    'edu_major': '专业',
    'notification_on': '消息推送',
  };

  static const _documentLabels = <String, String>{
    'user_agreement': '用户协议',
    'privacy_policy': '隐私政策',
    'community_rules': '社区规则',
    'minor_protection': '未成年人保护规则',
    'content_complaint_rules': '投诉举报规则',
    'sdk_disclosure': '第三方服务说明',
    'edu_data_consent': '教务数据专项授权',
  };

  Future<void> _saveCopy() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/shenliyuan-personal-data.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(widget.data),
      );
      await Share.shareXFiles([XFile(file.path)], text: '我的个人信息副本');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存副本失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.data['account'] is Map
        ? Map<String, dynamic>.from(widget.data['account'] as Map)
        : const <String, dynamic>{};
    final consents = widget.data['legal_consents'] is List
        ? (widget.data['legal_consents'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final active = widget.data['legal_consents_active'] == true;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = CampusTheme.pageBackground(context);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('我的个人信息'),
        actions: [
          IconButton(
            tooltip: '保存副本',
            onPressed: _saving ? null : _saveCopy,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
        physics: const BouncingScrollPhysics(),
        children: [
          Row(
            children: [
              const Expanded(child: _PrivacySectionTitle('账户资料')),
              Chip(label: Text(active ? '授权有效' : '授权未生效')),
            ],
          ),
          const SizedBox(height: 10),
          _PrivacySectionCard(
            children: _accountLabels.entries
                .where((entry) => account.containsKey(entry.key))
                .map(
                  (entry) => _DataRow(
                    label: entry.value,
                    value: _formatValue(entry.key, account[entry.key]),
                  ),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: 18),
          const _PrivacySectionTitle('授权记录'),
          const SizedBox(height: 10),
          if (consents.isEmpty)
            const _PrivacySectionCard(
              children: [
                Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('暂无可显示的授权记录'),
                ),
              ],
            )
          else
            _PrivacySectionCard(
              children: consents.map((consent) {
                final document = consent['document']?.toString() ?? '';
                final revoked = consent['revoked_at'] != null;
                return ListTile(
                  dense: true,
                  title: Text(_documentLabels[document] ?? document),
                  subtitle: Text(
                    '版本 ${consent['version'] ?? '-'} · ${revoked ? '已撤销' : '已同意'}',
                  ),
                  trailing: Icon(
                    revoked
                        ? Icons.remove_circle_outline
                        : Icons.check_circle_outline,
                    size: 20,
                    color: revoked
                        ? Theme.of(context).colorScheme.error
                        : (isDark ? const Color(0xFF62CDBD) : CampusTheme.primary),
                  ),
                );
              }).toList(growable: false),
            ),
          const SizedBox(height: 12),
          Text(
            widget.data['scope']?.toString() ?? '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  String _formatValue(String key, dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return '未填写';
    if (key == 'avatar_set' || key == 'background_set') {
      return value == true ? '已设置' : '未设置';
    }
    if (value is bool) return value ? '是' : '否';
    return value.toString();
  }
}

class _DataRow extends StatelessWidget {
  final String label;
  final String value;

  const _DataRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
               label,
               style: TextStyle(
                 color: Theme.of(context).colorScheme.onSurfaceVariant,
               ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
