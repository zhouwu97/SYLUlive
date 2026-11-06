import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';
import '../services/publish_session_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../widgets/app_card.dart';
import '../widgets/app_dialog.dart';
import '../widgets/campus/campus_theme.dart';
import '../widgets/security_session_guard.dart';
import '../widgets/settings/settings_page_scaffold.dart';

/// 教程只使用当前 API 配置的 origin，不接受授权响应中的任意跳转地址。
Uri? astrBotConnectionGuideUri(String apiBase, {Uri? pageUri}) {
  if (apiBase.trim().isEmpty) return null;
  final configured = Uri.tryParse(apiBase.trim());
  if (configured == null ||
      configured.hasQuery ||
      configured.hasFragment ||
      configured.userInfo.isNotEmpty) {
    return null;
  }
  if (!configured.hasScheme &&
      (!apiBase.trim().startsWith('/') || configured.hasAuthority)) {
    return null;
  }
  final origin = configured.hasScheme
      ? configured
      : (pageUri ?? Uri.base).resolveUri(configured);
  final localHttp = origin.scheme == 'http' &&
      {'localhost', '127.0.0.1', '::1'}.contains(origin.host);
  if (origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      (origin.scheme != 'https' && !localHttp)) {
    return null;
  }
  return origin.replace(
      path: '/web/connected-apps', queryParameters: const {'guide': 'astrbot'});
}

/// 原生设备授权使用与网页相同的请求、nonce 与独立 scope，不扩大旧连接。
class ManagedBotConnectionsScreen extends StatefulWidget {
  const ManagedBotConnectionsScreen({super.key});
  @override
  State<ManagedBotConnectionsScreen> createState() =>
      _ManagedBotConnectionsScreenState();
}

class _ManagedBotConnectionsScreenState
    extends State<ManagedBotConnectionsScreen> {
  static const _labels = {
    'profile:read_minimal': '账号编号与昵称',
    'community:read': '读取公开帖子、评论、作者昵称、互动统计和内置表情',
    'content:read_own_public': '读取本人公开帖子',
    'actions:read_own': '查看本授权创建的草稿和发布结果',
    'community:propose': '创建待本人确认的帖子或评论草稿',
    'checkin:write': '按本人指令签到（不含补签）',
    'community:bot_reply': '以独立 AI 机器人自动评论或发表情，不逐条确认',
    'community:bot_post': '以独立 AI 机器人自动发帖及使用已审核公开配图，每24小时最多1帖',
    'academic:grades:read': '读取本人主动同步的成绩，非学校实时查询',
    'academic:erke:read': '读取本人主动同步的二课摘要，非完整活动记录',
  };
  static const _sensitive = {
    'community:propose',
    'checkin:write',
    'community:bot_reply',
    'community:bot_post',
    'academic:grades:read',
    'academic:erke:read'
  };
  static const _personal = {'academic:grades:read', 'academic:erke:read'};
  String _scopeDisplayLabel(String scope) => _labels[scope] ?? scope;
  final _code = TextEditingController();
  PublishSessionScope? _session;
  Map<String, dynamic>? _consent;
  List<Map<String, dynamic>> _bindings = [];
  final _selected = <String>{};
  bool _loading = false, _busy = false, _checked = false, _replace = false;
  bool _connectionsLoaded = false, _requestExpanded = false;
  bool _openingGuide = false;
  bool? _personalEnabled;
  String? _error, _notice;
  String? _connectionError, _guideError;
  int _generation = 0;
  int _readGeneration = 0;

  bool _owns(PublishSessionScope session) =>
      mounted &&
      SecuritySessionGuard.owns(context.read<AuthProvider>(), session);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (auth.isLoggedIn &&
        _session?.owns(
                userId: auth.user?.id,
                sessionEpoch: auth.accountSessionEpoch) ==
            true) {
      return;
    }
    _generation++;
    _code.clear();
    _consent = null;
    _bindings = [];
    _personalEnabled = null;
    _connectionsLoaded = _requestExpanded = _openingGuide = false;
    _connectionError = _guideError = null;
    _selected.clear();
    _checked = _replace = _busy = false;
    _error = _notice = null;
    _session = auth.isLoggedIn && auth.user != null
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch)
        : null;
    _loading = _session != null;
    final session = _session;
    if (session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_owns(session)) _load();
      });
    }
  }

  String _problem(Object error) {
    final data = error is DioException ? error.response?.data : null;
    final code = data is Map ? data['code'] : null;
    return switch (code) {
      'recent_authentication_required' =>
        '批准需要30分钟内的本人验证，请先重新登录当前账号，再核对本次申请。一次验证可连续操作，拒绝和断开连接无需重复验证。',
      'academic_verification_required' => '请先在账号与安全完成受支持的教务身份核验。',
      'bot_reply_disabled' => '服务端尚未开放机器人自动评论，请先只授权读取或稍后重试。',
      'bot_post_disabled' => '服务端尚未开放机器人自动发帖，请先只授权读取或稍后重试。',
      'personal_queries_disabled' => '服务端尚未开放个人查询，请先取消选择成绩、二课权限。',
      'proposals_disabled' => '服务端尚未开放提案，请先只选择读取权限。',
      'binding_conflict' => '已有连接，请明确勾选替换后再授权。',
      'confirmation_expired' => '本次核对已过期，请在 AstrBot 重新获取一次性连接码。',
      'invalid_user_code' ||
      'expired_token' =>
        '连接码不存在或已过期，请在 AstrBot 发送 /sylu-connect 获取新码。',
      _ => '连接操作未完成，请重试；只核对自己刚在 AstrBot 获取的连接码。',
    };
  }

  Future<void> _load() async {
    final session = _session;
    if (session == null || !_owns(session)) return;
    final generation = _generation;
    final readGeneration = ++_readGeneration;
    setState(() {
      _loading = true;
      _connectionError = null;
      _personalEnabled = null;
      _error = null;
    });
    try {
      final response = await context.read<AuthProvider>().dio.get(
          '/connected-apps',
          options: Options(extra: session.requestExtra));
      if (!_owns(session) ||
          generation != _generation ||
          readGeneration != _readGeneration) {
        return;
      }
      final data = response.data;
      if (data is! Map || data['bindings'] is! List) {
        throw const FormatException('invalid connection list');
      }
      final bindings = <Map<String, dynamic>>[];
      for (final raw in data['bindings'] as List) {
        if (raw is! Map ||
            raw['binding_id'] is! String ||
            (raw['binding_id'] as String).isEmpty ||
            raw['state'] is! String ||
            (raw['installation_name'] != null &&
                raw['installation_name'] is! String) ||
            (raw['scopes'] != null && raw['scopes'] is! String)) {
          throw const FormatException('invalid connection item');
        }
        bindings.add(Map<String, dynamic>.from(raw));
      }
      setState(() {
        _personalEnabled = data['personal_data_enabled'] is bool
            ? data['personal_data_enabled'] as bool
            : null;
        _bindings = bindings;
        _connectionsLoaded = true;
      });
    } catch (e) {
      if (_owns(session) &&
          generation == _generation &&
          readGeneration == _readGeneration) {
        setState(() => _connectionError = _problem(e));
      }
    } finally {
      if (_owns(session) &&
          generation == _generation &&
          readGeneration == _readGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _lookup() async {
    final session = _session;
    if (session == null || !_owns(session) || _busy) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _consent = null;
      _selected.clear();
      _checked = _replace = false;
      _error = _notice = null;
    });
    try {
      final response = await context.read<AuthProvider>().dio.post(
          '/connected-apps/device-requests/lookup',
          data: {'user_code': _code.text.trim()},
          options: Options(extra: session.requestExtra));
      if (!_owns(session) || generation != _generation) return;
      final consent = Map<String, dynamic>.from(response.data as Map);
      setState(() {
        _consent = consent;
        _selected.addAll((consent['requested_scopes'] as List)
            .whereType<String>()
            .where((scope) =>
                _labels.containsKey(scope) && !_sensitive.contains(scope)));
      });
    } catch (e) {
      if (_owns(session) && generation == _generation) {
        setState(() => _error = _problem(e));
      }
    } finally {
      if (_owns(session) && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  bool get _validSelection =>
      _selected.isNotEmpty &&
      (!_selected.any(_personal.contains) || _personalEnabled == true) &&
      (!_selected.contains('community:propose') ||
          _selected.containsAll({'community:read', 'actions:read_own'})) &&
      (!_selected.contains('community:bot_reply') ||
          _selected.contains('community:propose')) &&
      (!_selected.contains('community:bot_post') ||
          _selected.contains('community:propose'));

  Future<void> _decide(bool allow) async {
    final session = _session, consent = _consent;
    if (session == null || consent == null || !_owns(session) || _busy) return;
    if (allow &&
        (!_validSelection ||
            !_checked ||
            (consent['existing_binding'] is Map && !_replace))) {
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = _notice = null;
    });
    try {
      final existing = consent['existing_binding'] as Map?;
      await context.read<AuthProvider>().dio.post(
          '/connected-apps/device-requests/${Uri.encodeComponent(consent['consent_id'] as String)}/decision',
          data: {
            'allow': allow,
            'scopes': allow ? _selected.toList() : <String>[],
            'confirmation_nonce': consent['confirmation_nonce'],
            'replace_binding_id': _replace ? (existing?['binding_id']) : '',
            'expected_epoch': _replace ? (existing?['epoch']) : 0
          },
          options: Options(extra: session.requestExtra));
      if (!_owns(session) || generation != _generation) return;
      setState(() {
        _consent = null;
        _code.clear();
        _requestExpanded = false;
        _notice = allow
            ? '授权已通过；请等待 AstrBot 完成连接，再返回机器人设置查看运行状态。'
            : '已拒绝这次申请，现有连接不受影响。';
      });
      await _load();
    } catch (e) {
      if (_owns(session) && generation == _generation) {
        setState(() => _error = _problem(e));
      }
    } finally {
      if (_owns(session) && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _revoke(Map<String, dynamic> binding) async {
    final session = _session;
    if (session == null || !_owns(session) || _busy) return;
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => SecuritySessionGuard(
            auth: auth,
            session: session,
            child: AppAlertDialog(
              title: const Text('断开这个 AstrBot？'),
              content: Text(
                  '「${binding['installation_name']}」将无法继续通过此连接浏览、发帖、回复或查询本人资料，旧凭证和待发布草稿会失效。机器人账号与已发布内容保留，其他连接不受影响。之后可以重新接入。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(44, 48),
                        visualDensity: VisualDensity.standard,
                        textStyle: Theme.of(context).textTheme.labelLarge),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认断开'))
              ],
            )));
    if (confirmed != true || !_owns(session)) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = _notice = null;
    });
    try {
      await auth.dio.post(
          '/connected-apps/${Uri.encodeComponent(binding['binding_id'] as String)}/revoke',
          options: Options(extra: session.requestExtra));
      if (!_owns(session) || generation != _generation) return;
      setState(() => _notice = '已断开此连接。重新接入时再获取一次性连接码。');
      await _load();
    } catch (e) {
      if (_owns(session) && generation == _generation) {
        setState(() => _error = _problem(e));
      }
    } finally {
      if (_owns(session) && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  List<Map<String, dynamic>> get _activeBindings =>
      _bindings.where((binding) => binding['state'] == 'active').toList();

  String _bindingSummary(Map<String, dynamic> binding) {
    final scopes = (binding['scopes'] as String? ?? '').split(' ').toSet();
    return [
      if (scopes.contains('community:read')) '公开浏览',
      if (scopes.contains('community:bot_reply')) '自动评论与回复',
      if (scopes.contains('community:bot_post')) '自动发帖',
      if (scopes.contains('checkin:write')) '本人签到',
      if (scopes.any(_personal.contains)) '本人资料查询',
    ].join('、');
  }

  void _closeRequest() {
    if (_busy) return;
    setState(() {
      _requestExpanded = false;
      _consent = null;
      _code.clear();
      _selected.clear();
      _checked = _replace = false;
      _error = null;
      _notice = '已取消本次核对，没有新增授权，也没有断开现有连接。';
    });
  }

  Future<void> _openGuide() async {
    if (_openingGuide) return;
    final uri = astrBotConnectionGuideUri(
        context.read<AuthProvider>().dio.options.baseUrl);
    if (uri == null) {
      setState(() => _guideError = '当前服务地址无法生成可信教程链接，请检查 App 的服务配置。');
      return;
    }
    final generation = _generation;
    setState(() {
      _openingGuide = true;
      _guideError = null;
    });
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted && generation == _generation && !opened) {
        setState(() => _guideError = '未能打开接入教程，请重试。连接状态没有改变。');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _guideError = '未能打开接入教程，请重试。连接状态没有改变。');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _openingGuide = false);
      }
    }
  }

  Widget _connectionOverview(BuildContext context, TextTheme text) {
    final active = _activeBindings;
    return _ConnectionSurface(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text('当前连接', style: text.titleMedium)),
          IconButton(
              key: const ValueKey('bot-refresh-connections'),
              tooltip: '刷新连接状态',
              onPressed: _busy || _loading || _session == null ? null : _load,
              icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: AppSpacing.sm),
        Text('当前账号：${context.watch<AuthProvider>().user?.nickname ?? '未登录'}'),
        const SizedBox(height: AppSpacing.md),
        if (_loading) ...[
          const Text('正在核对连接'),
          const SizedBox(height: AppSpacing.sm),
          const LinearProgressIndicator(),
        ] else if (_connectionError != null) ...[
          Text('连接状态暂未确认', style: text.titleSmall),
          Text(_connectionError!,
              style: text.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error)),
          TextButton(
              onPressed: _busy ? null : _load, child: const Text('重新读取连接')),
        ] else if (_session == null || !_connectionsLoaded) ...[
          const Text('登录当前账号后查看连接状态。'),
        ] else if (active.isEmpty) ...[
          Text('尚未连接 AstrBot', style: text.titleSmall),
          const Text('暂无有效连接。先在 AstrBot 私聊中发送 /sylu-connect，再在本页核对一次性连接码。'),
        ] else ...[
          Semantics(
              liveRegion: true,
              child: Text('已连接 AstrBot', style: text.titleSmall)),
          const Text('绑定已成功，无需重复填写连接码。连接授权不代表执行端在线，自动参与状态请回机器人设置查看。'),
          for (final binding in active) ...[
            const AppCardDivider(height: AppSpacing.xxl),
            Text(binding['installation_name'] as String? ?? '未命名 AstrBot',
                style: text.titleSmall),
            Text(_bindingSummary(binding).isEmpty
                ? '已授予的范围请展开核对。'
                : '已授予：${_bindingSummary(binding)}'),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看授权范围'),
              children: [
                Text((binding['scopes'] as String? ?? '')
                    .split(' ')
                    .where((scope) => scope.isNotEmpty)
                    .map(_scopeDisplayLabel)
                    .join('；'))
              ],
            ),
            TextButton.icon(
                onPressed: _busy ? null : () => _revoke(binding),
                icon: const Icon(Icons.link_off),
                label: const Text('断开连接')),
          ],
        ],
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          key: const ValueKey('bot-open-connection-request'),
          onPressed: _busy || _loading || _session == null || _requestExpanded
              ? null
              : () => setState(() {
                    _requestExpanded = true;
                    _notice = null;
                  }),
          style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
          icon: const Icon(Icons.add_link),
          label: Text(active.isEmpty ? '开始连接 AstrBot' : '连接新的 AstrBot'),
        ),
        const SizedBox(height: AppSpacing.sm),
        const Text('增加或调整授权范围时才需新的连接申请；不会自动扩展旧连接。'),
      ],
    ));
  }

  Widget _historySection(TextTheme text) {
    final history =
        _bindings.where((binding) => binding['state'] != 'active').toList();
    if (_loading || _connectionError != null || history.isEmpty) {
      return const SizedBox.shrink();
    }
    return _ConnectionSurface(
        child: ExpansionTile(
      key: ValueKey(
          'bot-connection-history-${_session?.accountId}-${_session?.accountSessionEpoch}'),
      tilePadding: EdgeInsets.zero,
      title: Text('历史连接（${history.length}）', style: text.titleMedium),
      subtitle: const Text('已失效的记录不代表仍在绑定，不影响当前连接。'),
      children: [
        for (final binding in history) ...[
          const AppCardDivider(height: AppSpacing.lg),
          Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  binding['installation_name'] as String? ?? '未命名 AstrBot',
                  style: text.titleSmall)),
          Align(
              alignment: Alignment.centerLeft,
              child: Text(binding['state'] == 'revoked'
                  ? '已断开，不能继续使用'
                  : '连接已失效；需要时重新发起连接')),
        ]
      ],
    ));
  }

  Widget _guideSection(TextTheme text) => _ConnectionSurface(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('接入 AstrBot 怎么操作？', style: text.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          const Text(
              '1. 已有机器人：私聊发送 /sylu-connect。\n2. 在本页核对账号、连接码和允许的范围。\n3. 回机器人设置保存并启用，再检查运行状态。'),
          const SizedBox(height: AppSpacing.sm),
          const Text('还没有部署 AstrBot？教程包含插件安装、模型配置、连接与排错步骤。实际授权仍可在 App 内完成。'),
          if (_guideError != null)
            Text(_guideError!,
                style: text.bodyMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.error)),
          TextButton.icon(
              onPressed: _openingGuide ? null : _openGuide,
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(_openingGuide ? '正在打开教程…' : '查看 AstrBot 接入教程')),
        ],
      ));

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = CampusTheme.withBrandAccent(Theme.of(context));
    final text = base.textTheme;
    final consent = _consent;
    final page = SettingsPageScaffold(
        title: 'AstrBot 连接与授权',
        appBarBackground: AppCardSurface(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.zero,
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.surfaceSecondaryDark
                    : AppColors.surfaceSecondaryLight),
            child: const SizedBox.expand()),
        onRefresh: _busy ? null : _load,
        children: [
          _connectionOverview(context, text),
          const SizedBox(height: AppSpacing.lg),
          if (_requestExpanded) ...[
            _ConnectionSurface(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('核对新的连接申请', style: text.titleMedium),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                      '在 AstrBot 私聊发送 /sylu-connect 获取连接码。它只用于本次核对，不是设备编号，也不表示已经绑定；已有连接无需重新填写。',
                      style: text.bodyMedium),
                  const SizedBox(height: AppSpacing.lg),
                  TextField(
                      key: const ValueKey('bot-device-code'),
                      controller: _code,
                      enabled: !_busy && _session != null,
                      maxLength: 16,
                      autocorrect: false,
                      decoration: const InputDecoration(
                          labelText: '连接码（一次性）', border: OutlineInputBorder()),
                      onChanged: (_) => setState(() {
                            _consent = null;
                            _checked = _replace = false;
                          })),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton(
                      onPressed:
                          _busy || _session == null || _code.text.trim().isEmpty
                              ? null
                              : _lookup,
                      style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.standard,
                          minimumSize: const Size(44, 48)),
                      child: Text(_busy ? '正在处理…' : '查看授权请求')),
                  TextButton(
                      onPressed: _busy ? null : _closeRequest,
                      child: const Text('取消本次核对')),
                  if (consent != null) ...[
                    const AppCardDivider(height: AppSpacing.xxl),
                    Text('授权给 ${consent['installation_name']}',
                        style: text.titleSmall),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                        '安装标识：${consent['installation_id']}\n名称和标识由插件提供，请核对代码：${consent['user_code']}'),
                    const SizedBox(height: AppSpacing.sm),
                    Text('有效至：${consent['expires_at']}'),
                    for (final scope in (consent['requested_scopes'] as List)
                        .whereType<String>())
                      CheckboxListTile(
                          key: ValueKey('bot-scope-$scope'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(_labels[scope] ?? '未知权限：$scope'),
                          subtitle: _personal.contains(scope) &&
                                  _personalEnabled != true
                              ? Text(_personalEnabled == false
                                  ? '服务端尚未开放个人查询，可先只授权其他权限。'
                                  : '尚未确认个人查询服务，请先刷新连接列表。')
                              : _sensitive.contains(scope)
                                  ? const Text('需你明确勾选，默认关闭')
                                  : null,
                          value: _selected.contains(scope),
                          onChanged: _busy ||
                                  !_labels.containsKey(scope) ||
                                  (_personal.contains(scope) &&
                                      _personalEnabled != true &&
                                      !_selected.contains(scope))
                              ? null
                              : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(scope);
                                    } else {
                                      _selected.remove(scope);
                                    }
                                  })),
                    const SizedBox(height: AppSpacing.sm),
                    const Text(
                        '公开内容、作者昵称和图片可交给你部署的 AstrBot，并可能继续发送至所选模型或记忆插件。平台不能收回已外发的数据。成绩、二课须本人另行同步并明确勾选后查询；不提供私信、学校密码或登录会话。'),
                    CheckboxListTile(
                        key: const ValueKey('bot-consent-confirm'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('我已核对连接码与当前账号，并了解外发范围'),
                        value: _checked,
                        onChanged: _busy
                            ? null
                            : (value) =>
                                setState(() => _checked = value == true)),
                    if (consent['existing_binding'] is Map)
                      CheckboxListTile(
                          key: const ValueKey('bot-consent-replace'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                              '撤销并替换已有授权「${consent['existing_binding']['installation_name']}」'),
                          value: _replace,
                          onChanged: _busy
                              ? null
                              : (value) =>
                                  setState(() => _replace = value == true)),
                    if (!_validSelection)
                      const Text('自动评论和发帖需同时选择公开读取、草稿结果与创建草稿权限。'),
                    Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: AppSpacing.sm,
                        children: [
                          TextButton(
                              onPressed: _busy ? null : () => _decide(false),
                              child: const Text('拒绝')),
                          FilledButton(
                              onPressed: _busy ||
                                      !_checked ||
                                      !_validSelection ||
                                      (consent['existing_binding'] is Map &&
                                          !_replace)
                                  ? null
                                  : () => _decide(true),
                              style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.standard,
                                  minimumSize: const Size(44, 48),
                                  textStyle: text.labelLarge),
                              child: const Text('授权此助手')),
                        ]),
                  ],
                ])),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (_error != null || _notice != null)
            _ConnectionSurface(
                child: Semantics(
                    liveRegion: true,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_error ?? _notice!,
                              style: text.bodyMedium?.copyWith(
                                  color: _error != null
                                      ? Theme.of(context).colorScheme.error
                                      : AppColors.success)),
                          if (_error != null)
                            TextButton(
                                onPressed: _busy ? null : _load,
                                child: const Text('重新读取连接')),
                        ]))),
          const SizedBox(height: AppSpacing.lg),
          _historySection(text),
          const SizedBox(height: AppSpacing.lg),
          _guideSection(text),
        ]);
    return Theme(
        data: base.copyWith(
            appBarTheme:
                base.appBarTheme.copyWith(titleTextStyle: text.titleLarge)),
        child: page);
  }
}

class _ConnectionSurface extends StatelessWidget {
  const _ConnectionSurface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AppCardSurface(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
            color: dark
                ? AppColors.surfaceSecondaryDark
                : AppColors.surfaceSecondaryLight,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
                color: dark
                    ? AppColors.borderNormalDark
                    : AppColors.borderNormalLight)),
        child: child);
  }
}
