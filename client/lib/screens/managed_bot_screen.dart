import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/publish_session_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../widgets/app_card.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/campus/campus_theme.dart';
import '../widgets/security_session_guard.dart';
import '../widgets/settings/settings_page_scaffold.dart';
import 'managed_bot_connections_screen.dart';

/// 账号、公开参与策略由服务端管理；私聊记忆仍只在本机 AstrBot 保存。
class ManagedBotScreen extends StatefulWidget {
  const ManagedBotScreen({super.key});

  @override
  State<ManagedBotScreen> createState() => _ManagedBotScreenState();
}

class _ManagedBotScreenState extends State<ManagedBotScreen> {
  final _name = TextEditingController(text: '大肥鱼');
  final _blockedTerms = TextEditingController();
  final _interval = TextEditingController(text: '30');
  PublishSessionScope? _session;
  Map<String, dynamic>? _data;
  bool _loading = false, _saving = false, _uploading = false, _dirty = false;
  String? _error, _notice;
  bool _unsupported = false;
  bool _resourceUnavailable = false;
  bool _permissionsExpanded = false, _speechExpanded = false;
  bool _privacyExpanded = false, _technicalExpanded = false;
  String _avatar = '';
  Map<String, dynamic> _policy = _defaultPolicy();
  int _generation = 0;
  Timer? _runtimeTimer;
  bool _runtimeRefreshing = false, _runtimeUnverified = false;
  int _runtimeGeneration = 0;

  static Map<String, dynamic> _defaultPolicy() => {
        'public_read_enabled': true,
        'reply_enabled': false,
        'sticker_enabled': false,
        'post_enabled': false,
        'image_enabled': false,
        'allowed_post_types': <String>['campus_life', 'course_study'],
        'blocked_terms': <String>[],
        'block_links': true,
        'daily_reply_limit': 3,
        'min_reply_interval_minutes': 30,
      };

  bool get _busy => _saving || _uploading;
  bool get _supportsPolicy => _data?['policy_supported'] == true;
  Map? get _bot => _data?['bot'] as Map?;
  List<String> get _unavailableSectionSlugs {
    if (!_supportsPolicy) return const [];
    final available = (_data?['sections'] as List? ?? [])
        .whereType<Map>()
        .map((section) => section['slug'])
        .toSet();
    return List<String>.from(_policy['allowed_post_types'] as List? ?? [])
        .where((slug) => !available.contains(slug))
        .toList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_session?.owns(
                userId: auth.user?.id,
                sessionEpoch: auth.accountSessionEpoch) ==
            true &&
        auth.isLoggedIn) {
      return;
    }
    _generation++;
    _runtimeGeneration++;
    _runtimeTimer?.cancel();
    _runtimeRefreshing = _runtimeUnverified = false;
    _data = null;
    _saving = _uploading = _dirty = false;
    _notice = null;
    _unsupported = false;
    _resourceUnavailable = false;
    _permissionsExpanded =
        _speechExpanded = _privacyExpanded = _technicalExpanded = false;
    _name.text = '大肥鱼';
    _avatar = '';
    _policy = _defaultPolicy();
    _blockedTerms.clear();
    _interval.text = '30';
    _session = auth.isLoggedIn && auth.user != null
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch)
        : null;
    _loading = _session != null;
    _error = _session == null ? '请先登录后管理机器人' : null;
    final session = _session;
    if (session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_owns(session)) _reload();
      });
    }
  }

  bool _owns(PublishSessionScope session) =>
      mounted &&
      SecuritySessionGuard.owns(context.read<AuthProvider>(), session);

  String _problem(Object error) {
    final response = error is DioException ? error.response : null;
    final data = response?.data;
    final code = data is Map ? data['code'] : null;
    return switch (code) {
      'recent_authentication_required' => '请重新登录验证本人身份，再创建、编辑或启用机器人。暂停无需重新验证。',
      'academic_verification_required' => '请先在账号与安全中完成受支持的教务身份核验。',
      'community_rules_required' => '请先在校园社区阅读并接受现行社区规则。',
      'invalid_bot_name' => '请输入1–24个字符的机器人名称。',
      'invalid_bot_avatar' => '头像不可用，请重新上传本人选择的图片。',
      'invalid_bot_policy' => '社区权限未通过校验，请检查板块、屏蔽词与发言频率。',
      'account_unavailable' => '当前账号不可用，请检查账号状态。',
      'resource_unavailable' => '已有机器人资料暂时不可用，请重试或联系维护者核对。',
      _ when response?.statusCode == 404 =>
        '机器人管理接口不可用（HTTP 404）。请维护者检查服务版本、功能开关与路由配置。',
      _ => '操作未完成，请重试。若保存请求超时，先重新读取状态核对结果。',
    };
  }

  Future<void> _reload() async {
    final session = _session;
    if (session == null || !_owns(session) || _busy) return;
    final generation = ++_generation;
    _runtimeGeneration++;
    _runtimeRefreshing = false;
    setState(() {
      _loading = true;
      _error = null;
      _unsupported = false;
      _resourceUnavailable = false;
    });
    try {
      final result = await context.read<AuthProvider>().dio.get(
          '/connected-apps/bot',
          options: Options(extra: session.requestExtra));
      if (!_owns(session) || generation != _generation) return;
      final data = Map<String, dynamic>.from(result.data as Map);
      setState(() {
        _data = data;
        _runtimeUnverified = false;
        if (!_dirty) {
          final bot = data['bot'];
          _name.text =
              bot is Map && bot['name'] is String ? bot['name'] : '大肥鱼';
          _avatar = bot is Map && bot['avatar'] is String ? bot['avatar'] : '';
          _policy = _defaultPolicy();
          if (bot is Map && bot['policy'] is Map) {
            _policy.addAll(Map<String, dynamic>.from(bot['policy'] as Map));
          }
          _blockedTerms.text =
              (_policy['blocked_terms'] as List? ?? []).join('\n');
          _interval.text = '${_policy['min_reply_interval_minutes']}';
        }
      });
      _runtimeTimer?.cancel();
      if (data['runtime_supported'] == true && data['bot'] != null) {
        _runtimeTimer = Timer.periodic(
            const Duration(seconds: 30), (_) => _refreshRuntime());
      }
    } catch (e) {
      if (_owns(session) && generation == _generation) {
        setState(() {
          _error = _problem(e);
          final errorData = e is DioException ? e.response?.data : null;
          _resourceUnavailable =
              errorData is Map && errorData['code'] == 'resource_unavailable';
          _unsupported = e is DioException &&
              e.response?.statusCode == 404 &&
              !_resourceUnavailable;
        });
      }
    } finally {
      if (_owns(session) && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshRuntime() async {
    final session = _session;
    if (session == null ||
        !_owns(session) ||
        _busy ||
        _loading ||
        _runtimeRefreshing ||
        _data?['runtime_supported'] != true) {
      return;
    }
    final generation = ++_runtimeGeneration;
    setState(() => _runtimeRefreshing = true);
    try {
      final response = await context.read<AuthProvider>().dio.get(
          '/connected-apps/bot/runtime',
          options: Options(extra: session.requestExtra));
      if (!_owns(session) || generation != _runtimeGeneration) return;
      final body = response.data;
      if (body is! Map || body['runtime'] is! Map) {
        throw const FormatException('invalid runtime');
      }
      setState(() {
        _data = {...?_data, 'runtime': body['runtime']};
        _runtimeUnverified = false;
      });
    } catch (_) {
      if (_owns(session) && generation == _runtimeGeneration) {
        setState(() => _runtimeUnverified = true);
      }
    } finally {
      if (_owns(session) && generation == _runtimeGeneration) {
        setState(() => _runtimeRefreshing = false);
      }
    }
  }

  Future<void> _save({bool? enabled, bool pauseOnly = false}) async {
    final session = _session;
    if (session == null || !_owns(session) || _busy || _loading) return;
    if (!_supportsPolicy && !pauseOnly) return;
    final existed = _bot != null;
    final isEnabled = enabled ?? _bot?['enabled'] == true;
    final name = _name.text.trim();
    final terms = _blockedTerms.text
        .split(RegExp(r'[\n,，]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    if (!pauseOnly && (name.isEmpty || name.runes.length > 24)) {
      setState(() => _error = '请输入1–24个字符的机器人名称。');
      return;
    }
    if (!pauseOnly &&
        _supportsPolicy &&
        (terms.length > 20 || terms.any((value) => value.runes.length > 24))) {
      setState(() => _error = '屏蔽词最多20个，每个不超过24个字符。');
      return;
    }
    final interval = _policy['min_reply_interval_minutes'] as int;
    if (!pauseOnly && _supportsPolicy && (interval < 1 || interval > 1440)) {
      setState(() => _error = '最短发言间隔须为1–1440分钟。');
      return;
    }
    final body = pauseOnly
        ? <String, dynamic>{'enabled': false}
        : <String, dynamic>{
            'name': name,
            'enabled': isEnabled,
            if (_supportsPolicy) 'avatar': _avatar,
            if (_supportsPolicy) 'policy': {..._policy, 'blocked_terms': terms},
          };
    setState(() {
      _saving = true;
      _error = _notice = null;
    });
    try {
      await context.read<AuthProvider>().dio.post('/connected-apps/bot',
          data: body, options: Options(extra: session.requestExtra));
      if (!_owns(session)) return;
      setState(() {
        _saving = false;
        // 暂停不覆盖尚未保存的资料草稿。
        if (!pauseOnly) _dirty = false;
        _notice = pauseOnly
            ? '机器人已暂停，新的自动发言会被服务端拒绝。'
            : !existed
                ? '机器人已新建，当前已暂停。设置好权限并连接 AstrBot 后可启用。'
                : '资料与权限已保存${isEnabled ? '，机器人已启用' : '，机器人保持暂停'}。';
      });
      await _reload();
    } catch (e) {
      if (_owns(session)) {
        setState(() {
          _saving = false;
          _error = _problem(e);
        });
      }
    }
  }

  Future<void> _pickAvatar() async {
    final session = _session;
    final dio = context.read<AuthProvider>().dio;
    if (session == null || !_owns(session) || _busy || !_supportsPolicy) return;
    setState(() {
      _uploading = true;
      _error = _notice = null;
    });
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null || !_owns(session)) return;
      final cropped = await ImageCropper().cropImage(
        sourcePath: picked.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        maxWidth: 1024,
        maxHeight: 1024,
        compressQuality: 85,
        compressFormat: ImageCompressFormat.jpg,
        uiSettings: [
          AndroidUiSettings(
              toolbarTitle: '裁剪机器人头像',
              initAspectRatio: CropAspectRatioPreset.square,
              lockAspectRatio: true),
          IOSUiSettings(title: '裁剪机器人头像', aspectRatioLockEnabled: true),
        ],
      );
      if (cropped == null || !_owns(session)) return;
      final bytes = await cropped.readAsBytes();
      if (!_owns(session)) return;
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        setState(() => _error = '请选择10MB以内的有效图片。');
        return;
      }
      final response = await dio.post('/upload',
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(bytes,
                filename: 'bot_avatar.jpg',
                contentType: DioMediaType('image', 'jpeg'))
          }),
          options: Options(extra: session.requestExtra));
      if (!_owns(session)) return;
      final url = response.data is Map ? response.data['url'] : null;
      if (url is! String || !url.startsWith('/uploads/')) {
        setState(() => _error = '头像上传结果不可用，请重新选择。');
        return;
      }
      setState(() {
        _avatar = url;
        _dirty = true;
        _notice = '头像已上传，保存资料后生效。';
      });
    } catch (e) {
      if (_owns(session)) setState(() => _error = '头像未能上传，请确认相册权限或重新选择图片。');
    } finally {
      if (_owns(session)) setState(() => _uploading = false);
    }
  }

  void _changePolicy(String key, dynamic value) => setState(() {
        _policy[key] = value;
        _dirty = true;
      });

  Future<void> _connections() async {
    final session = _session;
    if (session == null || !_owns(session) || _busy) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const ManagedBotConnectionsScreen()));
    if (_owns(session)) await _reload();
  }

  @override
  void dispose() {
    _runtimeTimer?.cancel();
    _name.dispose();
    _blockedTerms.dispose();
    _interval.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = CampusTheme.withBrandAccent(Theme.of(context));
    return Theme(
      data: base.copyWith(
          appBarTheme: base.appBarTheme
              .copyWith(titleTextStyle: base.textTheme.titleLarge)),
      child: Builder(builder: (context) {
        final text = Theme.of(context).textTheme;
        final bot = _bot;
        return SettingsPageScaffold(
          title: '我的 AI 机器人',
          appBarBackground: AppCardSurface(
            key: const ValueKey('bot-appbar-surface'),
            decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.surfaceSecondaryDark
                    : AppColors.surfaceSecondaryLight,
                borderRadius: BorderRadius.zero),
            child: const SizedBox.expand(),
          ),
          onRefresh: _reload,
          actions: [
            IconButton(
                tooltip: '重新读取机器人状态',
                visualDensity: VisualDensity.standard,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed:
                    _loading || _busy || _session == null ? null : _reload,
                icon: const Icon(Icons.refresh))
          ],
          children: [
            // 读取失败只表示状态未知，不能把已有机器人当作尚未创建。
            if (_data == null)
              _unavailable(context)
            else ...[
              if (_error != null) ...[
                _BotFeedback(
                    message: _error!,
                    error: true,
                    action: TextButton.icon(
                        onPressed: _loading || _busy ? null : _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新读取状态'))),
                const SizedBox(height: AppSpacing.lg),
              ],
              _profile(context),
              if (_notice != null) ...[
                const SizedBox(height: AppSpacing.md),
                _BotFeedback(message: _notice!),
              ],
              const SizedBox(height: AppSpacing.lg),
              if (_supportsPolicy)
                _permissions(context)
              else
                _BotSurface(
                    surfaceKey: const ValueKey('bot-legacy-surface'),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _BotCondition(
                              icon: Icons.info_outline, text: '当前服务仅支持基础资料'),
                          const SizedBox(height: AppSpacing.sm),
                          Text('升级服务端后可编辑资料和权限；已有机器人仍可暂停。',
                              style: text.bodyMedium),
                        ])),
            ],
            if (_session != null) ...[
              const SizedBox(height: AppSpacing.lg),
              _connection(context),
            ],
            const SizedBox(height: AppSpacing.lg),
            _privacy(context),
            if (bot != null) const SizedBox(height: AppSpacing.sm),
          ],
        );
      }),
    );
  }

  Widget _unavailable(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final loggedOut = _session == null;
    return _BotSurface(
      surfaceKey:
          ValueKey(_loading ? 'bot-loading-surface' : 'bot-error-surface'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              _loading
                  ? Icons.sync
                  : loggedOut
                      ? Icons.lock_outline
                      : Icons.cloud_off_outlined,
              color: _loading || loggedOut
                  ? scheme.onSurfaceVariant
                  : scheme.error,
              size: 28),
          const SizedBox(width: AppSpacing.md),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    _loading
                        ? '正在读取机器人状态…'
                        : loggedOut
                            ? '登录后管理机器人'
                            : _resourceUnavailable
                                ? '机器人资料暂时不可用'
                                : _unsupported
                                    ? '管理服务尚未就绪'
                                    : '暂时无法加载机器人',
                    style: text.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                    _loading
                        ? '正在同步资料与社区权限。'
                        : loggedOut
                            ? '登录账号后可管理独立机器人。'
                            : _resourceUnavailable
                                ? '已有资料暂时未能读取，请重试或联系维护者核对。'
                                : _unsupported
                                    ? '当前连接的服务暂未开放此功能。请联系维护者检查服务版本与配置。'
                                    : '当前资料尚未加载。请重试，或展开详细说明查看原因。',
                    style: text.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ])),
        ]),
        if (_unsupported && !_loading) ...[
          const SizedBox(height: AppSpacing.md),
          Text('暂未读到资料，已有机器人不会改变。',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        if (_loading) ...[
          const SizedBox(height: AppSpacing.lg),
          const LinearProgressIndicator(),
        ] else if (!loggedOut) ...[
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                  onPressed: _busy ? null : _reload,
                  style: _primaryStyle(context),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新读取状态'))),
          const SizedBox(height: AppSpacing.sm),
          _BotDisclosure(
              disclosureKey: const ValueKey('bot-technical-toggle'),
              title: '查看详细说明',
              expanded: _technicalExpanded,
              onTap: () =>
                  setState(() => _technicalExpanded = !_technicalExpanded)),
          if (_technicalExpanded)
            Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(_error ?? '尚未获取服务端状态。', style: text.bodySmall)),
        ],
      ]),
    );
  }

  Widget _profile(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final bot = _bot;
    final owner = bot?['owner'];
    final ownerName = owner is Map && owner['nickname'] is String
        ? owner['nickname'] as String
        : context.read<AuthProvider>().user?.nickname ?? '我';
    final disabled = _busy || _loading || !_supportsPolicy;
    return _BotSurface(
        surfaceKey: const ValueKey('bot-management-surface'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(
                label: '机器人头像',
                child: CachedAvatar(
                    imageUrl: _avatar,
                    radius: 26,
                    fallbackIcon: Icons.account_circle_outlined,
                    fallbackBackgroundColor: scheme.primaryContainer,
                    fallbackIconColor: scheme.primary)),
            const SizedBox(width: AppSpacing.md),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      bot == null ? '新建机器人' : bot['name'] as String? ?? '机器人资料',
                      style: text.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text('$ownerName 的 AI',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (bot != null)
                    Text('独立账号 #${bot['bot_user_id']}',
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                ])),
            if (_supportsPolicy)
              IconButton(
                  key: const ValueKey('bot-avatar-picker'),
                  visualDensity: VisualDensity.standard,
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                  tooltip: _uploading ? '正在处理头像' : '编辑机器人头像',
                  onPressed: disabled ? null : _pickAvatar,
                  icon: Icon(_uploading
                      ? Icons.hourglass_top
                      : Icons.add_photo_alternate_outlined)),
          ]),
          const SizedBox(height: AppSpacing.md),
          _BotCondition(
              icon: bot == null
                  ? Icons.add_circle_outline
                  : bot['enabled'] == true
                      ? Icons.check_circle_outline
                      : Icons.pause_circle_outline,
              text: _error != null
                  ? '状态未更新，以下为上次确认的资料'
                  : _loading
                      ? '正在更新，以下为上次确认的资料'
                      : bot == null
                          ? '尚未创建机器人'
                          : bot['enabled'] == true
                              ? '机器人已启用'
                              : '机器人已暂停',
              success: _error == null && !_loading && bot?['enabled'] == true),
          const SizedBox(height: AppSpacing.lg),
          TextField(
              key: const ValueKey('bot-name'),
              controller: _name,
              enabled: !disabled,
              maxLength: 24,
              decoration: _input('机器人名字', helper: '名字与头像公开显示，附带 AI 和创建者标识'),
              onChanged: (_) => setState(() => _dirty = true)),
          if (_avatar.isNotEmpty)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: disabled
                        ? null
                        : () => setState(() {
                              _avatar = '';
                              _dirty = true;
                            }),
                    child: const Text('使用默认头像'))),
          if (_dirty) ...[
            const SizedBox(height: AppSpacing.sm),
            const _BotCondition(icon: Icons.edit_outlined, text: '有未保存修改'),
          ],
          const SizedBox(height: AppSpacing.md),
          SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                  key: const ValueKey('bot-save-profile'),
                  onPressed: disabled ||
                          _name.text.trim().isEmpty ||
                          _unavailableSectionSlugs.isNotEmpty
                      ? null
                      : () => _save(enabled: bot?['enabled'] == true),
                  style: _primaryStyle(context),
                  icon: Icon(_saving
                      ? Icons.hourglass_top
                      : bot == null
                          ? Icons.add
                          : Icons.save_outlined),
                  label: Text(_saving
                      ? '正在保存…'
                      : bot == null
                          ? '创建机器人'
                          : '保存资料与权限'))),
          if (_unavailableSectionSlugs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('请先在社区权限中处理不可用板块，再保存或启用。',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
          if (bot == null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('创建后默认暂停，每个账号可创建一个机器人。',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                    onPressed: _busy ||
                            _loading ||
                            (bot['enabled'] != true &&
                                (!_supportsPolicy ||
                                    _unavailableSectionSlugs.isNotEmpty))
                        ? null
                        : () => bot['enabled'] == true
                            ? _save(pauseOnly: true)
                            : _save(enabled: true),
                    style: _secondaryStyle(context),
                    icon: Icon(bot['enabled'] == true
                        ? Icons.pause
                        : Icons.play_arrow),
                    label: Text(bot['enabled'] == true ? '暂停机器人' : '启用机器人'))),
          ],
        ]));
  }

  Widget _permissions(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final disabled = _busy || _loading;
    final reading = _policy['public_read_enabled'] == true;
    final sections =
        (_data?['sections'] as List? ?? []).whereType<Map>().toList();
    final selected =
        List<String>.from(_policy['allowed_post_types'] as List? ?? []);
    final selectedCount =
        sections.where((section) => selected.contains(section['slug'])).length;
    final terms = _blockedTerms.text
        .split(RegExp(r'[\n,，]'))
        .map((term) => term.trim())
        .where((term) => term.isNotEmpty)
        .toSet()
        .length;
    final daily = (_policy['daily_reply_limit'] as int?)?.clamp(1, 100) ?? 3;
    final interval = _policy['min_reply_interval_minutes'] as int;
    // 能力和节奏控件只编辑草稿，保存后仍由服务端核验实际权限。
    final capabilities = [
      ('reply_enabled', '自动文字评论', '无需逐条确认', Icons.chat_bubble_outline),
      ('sticker_enabled', '内置表情', '只发平台内置表情', Icons.emoji_emotions_outlined),
      ('post_enabled', '自动发布帖子', '每24小时最多1帖', Icons.article_outlined),
      ('image_enabled', '公开配图', '只用已审核公开素材', Icons.image_outlined),
    ];
    final count =
        capabilities.where((entry) => _policy[entry.$1] == true).length;
    return _BotSurface(
        surfaceKey: const ValueKey('bot-permissions-surface'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _BotDisclosure(
              disclosureKey: const ValueKey('bot-permissions-toggle'),
              title: '社区权限',
              subtitle:
                  '${_dirty ? '待保存 · ' : ''}${!reading ? '浏览已关，发言暂停' : selectedCount == 0 ? '未选板块，无法参与' : '公开浏览 · 已选$selectedCount/${sections.length}板块 · 发言$count项'}${_unavailableSectionSlugs.isNotEmpty ? ' · 有失效板块' : ''}',
              expanded: _permissionsExpanded,
              onTap: () =>
                  setState(() => _permissionsExpanded = !_permissionsExpanded)),
          if (_permissionsExpanded) ...[
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile.adaptive(
                key: const ValueKey('bot-policy-public_read_enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text('公开浏览总闸', style: text.titleSmall),
                subtitle: const Text('关闭后保留选择，暂停所有浏览和发言。'),
                secondary: Icon(Icons.public, color: scheme.onSurfaceVariant),
                value: reading,
                onChanged: disabled
                    ? null
                    : (value) => _changePolicy('public_read_enabled', value)),
            const SizedBox(height: AppSpacing.lg),
            Row(children: [
              Expanded(child: Text('允许的发言方式', style: text.titleSmall)),
              Text(reading ? '可组合选择' : '已暂停',
                  style:
                      text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
            ]),
            const SizedBox(height: AppSpacing.md),
            LayoutBuilder(builder: (context, constraints) {
              final stack = constraints.maxWidth < 280 ||
                  MediaQuery.textScalerOf(context).scale(14) > 16.8;
              final controls = [
                for (final entry in capabilities)
                  _BotCapabilityControl(
                      controlKey: ValueKey('bot-policy-${entry.$1}'),
                      title: entry.$2,
                      description: entry.$3,
                      icon: entry.$4,
                      selected: _policy[entry.$1] == true,
                      enabled: !disabled &&
                          reading &&
                          (entry.$1 != 'image_enabled' ||
                              _policy['post_enabled'] == true),
                      onChanged: (value) => _changePolicy(entry.$1, value))
              ];
              return Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: [
                    for (final control in controls)
                      SizedBox(
                          width: stack
                              ? constraints.maxWidth
                              : (constraints.maxWidth - AppSpacing.md) / 2,
                          child: control)
                  ]);
            }),
            const SizedBox(height: AppSpacing.xl),
            Row(children: [
              Expanded(child: Text('访问范围', style: text.titleSmall)),
              Text('已选 $selectedCount / ${sections.length}',
                  key: const ValueKey('bot-section-count'),
                  style: text.labelMedium)
            ]),
            const SizedBox(height: AppSpacing.xs),
            Text('只在选中的公开板块浏览和发言。',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.sm),
            if (sections.isEmpty)
              const Text('暂无可选公开板块，机器人不能浏览或发言。')
            else
              Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final section in sections)
                      FilterChip(
                          key: ValueKey('bot-section-${section['slug']}'),
                          label: Text(section['name'] as String? ??
                              section['slug'].toString()),
                          selected: selected.contains(section['slug']),
                          showCheckmark: true,
                          visualDensity: VisualDensity.standard,
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          selectedColor: scheme.primary.withValues(alpha: .1),
                          backgroundColor: Colors.transparent,
                          disabledColor:
                              scheme.onSurface.withValues(alpha: .04),
                          labelStyle: text.labelLarge
                              ?.copyWith(color: scheme.onSurface),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.md)),
                          side: BorderSide(
                              color:
                                  selected.contains(section['slug']) && reading
                                      ? scheme.primary
                                      : scheme.outlineVariant),
                          onSelected: disabled || !reading
                              ? null
                              : (value) {
                                  final next = selected
                                      .where((slug) => sections
                                          .any((item) => item['slug'] == slug))
                                      .toList();
                                  if (value) {
                                    if (!next.contains(section['slug'])) {
                                      next.add(section['slug'] as String);
                                    }
                                  } else {
                                    next.remove(section['slug']);
                                  }
                                  _changePolicy('allowed_post_types', next);
                                }),
                  ]),
            if (sections.isNotEmpty && selectedCount == 0) ...[
              const SizedBox(height: AppSpacing.sm),
              const _BotCondition(icon: Icons.block, text: '未选择板块，机器人不会浏览或发言。'),
            ],
            if (_unavailableSectionSlugs.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('有${_unavailableSectionSlugs.length}个所选板块当前不可用，请重新选择或移除后保存。',
                  style: text.bodySmall),
              TextButton.icon(
                  key: const ValueKey('bot-remove-unavailable-sections'),
                  onPressed: disabled
                      ? null
                      : () => _changePolicy(
                          'allowed_post_types',
                          selected
                              .where((slug) =>
                                  !_unavailableSectionSlugs.contains(slug))
                              .toList()),
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('移除失效板块')),
            ],
            const SizedBox(height: AppSpacing.md),
            const _BotCondition(
                icon: Icons.lock_outline, text: '不访问私信、教务资料或管理后台。'),
          ],
          const AppCardDivider(height: AppSpacing.xl),
          _BotDisclosure(
              disclosureKey: const ValueKey('bot-speech-toggle'),
              title: '发言规则',
              subtitle:
                  '${_dirty ? '待保存 · ' : ''}$daily条/24小时 · 至少$interval分钟 · $terms个屏蔽词',
              expanded: _speechExpanded,
              onTap: () => setState(() => _speechExpanded = !_speechExpanded)),
          if (_speechExpanded) ...[
            const SizedBox(height: AppSpacing.md),
            Text('发言节奏', style: text.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text('快捷选择只修改草稿，保存后生效。',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.md),
            Text('每24小时最多', style: text.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
                width: double.infinity,
                child: DropdownButton<int>(
                    key: const ValueKey('bot-daily-limit'),
                    isExpanded: true,
                    itemHeight: 48,
                    menuMaxHeight: 320,
                    items: [
                      for (var value = 1; value <= 100; value++)
                        DropdownMenuItem(value: value, child: Text('$value 条'))
                    ],
                    value: daily,
                    onChanged: disabled
                        ? null
                        : (value) {
                            if (value != null) {
                              _changePolicy('daily_reply_limit', value);
                            }
                          })),
            Text('可选1–100条；文字、表情与具体评论回复合计。保存后生效。',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.lg),
            Text('两次发言至少间隔', style: text.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
              for (final value in [1, 5, 30, 60, 120])
                ChoiceChip(
                    key: ValueKey('bot-interval-preset-$value'),
                    label: Text('$value 分钟'),
                    selected: interval == value,
                    showCheckmark: true,
                    visualDensity: VisualDensity.standard,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    selectedColor: scheme.primary.withValues(alpha: .1),
                    backgroundColor: Colors.transparent,
                    labelStyle:
                        text.labelLarge?.copyWith(color: scheme.onSurface),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md)),
                    side: BorderSide(
                        color: interval == value
                            ? scheme.primary
                            : scheme.outlineVariant),
                    onSelected: disabled
                        ? null
                        : (_) {
                            _interval.text = '$value';
                            _changePolicy('min_reply_interval_minutes', value);
                          }),
            ]),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
                key: const ValueKey('bot-interval'),
                controller: _interval,
                enabled: !disabled,
                keyboardType: TextInputType.number,
                decoration: _input('自定义间隔（分钟）', helper: '1–1440分钟；同一目标不重复回复'),
                onChanged: (value) => _changePolicy(
                    'min_reply_interval_minutes', int.tryParse(value) ?? 0)),
            const AppCardDivider(height: AppSpacing.xxl),
            Text('内容限制', style: text.titleSmall),
            const SizedBox(height: AppSpacing.md),
            SwitchListTile.adaptive(
                key: const ValueKey('bot-policy-block_links'),
                contentPadding: EdgeInsets.zero,
                title: const Text('禁止发布链接'),
                subtitle: const Text('含网址的帖子和评论会被拦截'),
                value: _policy['block_links'] == true,
                onChanged: disabled
                    ? null
                    : (value) => _changePolicy('block_links', value)),
            const SizedBox(height: AppSpacing.md),
            TextField(
                key: const ValueKey('bot-blocked-terms'),
                controller: _blockedTerms,
                enabled: !disabled,
                minLines: 2,
                maxLines: 5,
                decoration:
                    _input('禁止出现的词语', helper: '每行一个或逗号分隔，最多20个，每个24字以内'),
                onChanged: (_) => setState(() => _dirty = true)),
          ],
          if (_dirty) ...[
            const SizedBox(height: AppSpacing.lg),
            const _BotCondition(
                icon: Icons.edit_outlined, text: '待保存，当前修改尚未生效'),
            if (_bot != null) ...[
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                      key: const ValueKey('bot-save-policy'),
                      onPressed: disabled ||
                              interval < 1 ||
                              interval > 1440 ||
                              _unavailableSectionSlugs.isNotEmpty
                          ? null
                          : () => _save(),
                      style: _primaryStyle(context),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存社区权限'))),
            ],
          ],
        ]));
  }

  Widget _connection(BuildContext context) => _BotSurface(
      surfaceKey: const ValueKey('bot-connection-surface'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('连接与授权', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          ..._runtimeStatus(context),
          _BotCondition(
              icon: _data == null || _error != null || _loading
                  ? Icons.help_outline
                  : _data!['auto_reply_server_enabled'] == true
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
              text: _loading
                  ? '自动评论服务：正在核验'
                  : _data == null || _error != null
                      ? '自动评论服务：尚未核验'
                      : '自动评论服务：${_data!['auto_reply_server_enabled'] == true ? '已开放' : '暂未开放'}'),
          const SizedBox(height: AppSpacing.sm),
          _BotCondition(
              icon: _data == null || _error != null || _loading
                  ? Icons.help_outline
                  : _data!['auto_reply_authorized'] == true
                      ? Icons.verified_user_outlined
                      : Icons.lock_outline,
              text: _loading
                  ? '专用评论授权：正在核验'
                  : _data == null || _error != null
                      ? '专用评论授权：尚未核验'
                      : '专用评论授权：${_data!['auto_reply_authorized'] == true ? '已授权' : '尚未授权'}'),
          const SizedBox(height: AppSpacing.sm),
          _BotCondition(
              icon: Icons.article_outlined,
              text: _loading
                  ? '自动发帖服务：正在核验'
                  : _data == null || _error != null
                      ? '自动发帖服务：尚未核验'
                      : '自动发帖服务：${_data!['auto_post_server_enabled'] == true ? '已开放' : '暂未开放'}'),
          const SizedBox(height: AppSpacing.sm),
          _BotCondition(
              icon: Icons.verified_user_outlined,
              text: _loading
                  ? '专用发帖授权：正在核验'
                  : _data == null || _error != null
                      ? '专用发帖授权：尚未核验'
                      : '专用发帖授权：${_data!['auto_post_authorized'] == true ? '已授权' : '尚未授权'}'),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                  onPressed: _busy || _loading ? null : _connections,
                  style: _secondaryStyle(context),
                  icon: const Icon(Icons.link),
                  label: const Text('管理 AstrBot 连接与授权'))),
          const SizedBox(height: AppSpacing.sm),
          Text('查看当前连接、按需核对一次性连接码，接入教程也在其中。账号启用与执行端在线分别核实。',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ));

  List<Widget> _runtimeStatus(BuildContext context) {
    const labels = {
      'not_created': '尚未创建',
      'paused': '已暂停',
      'read_disabled': '公开浏览未开放',
      'scope_required': 'AstrBot 尚未获得公开社区读取权限',
      'offline': '执行端离线或尚未连接',
      'syncing': '正在同步新权限',
      'idle': '等待下一轮',
      'waiting': '排队中',
      'loading': '正在浏览',
      'completed': '本轮已完成',
      'empty': '暂无符合条件的帖子',
      'error': '执行失败',
      'disabled': '执行端未开启自动浏览',
      'cooldown': '等待下次执行',
    };
    final supported = _data?['runtime_supported'] == true;
    final runtime =
        _data?['runtime'] is Map ? _data!['runtime'] as Map : const {};
    final verified = !_loading &&
        _error == null &&
        !_runtimeUnverified &&
        !_runtimeRefreshing;
    var state = runtime['state'];
    final lastSeen = DateTime.tryParse('${runtime['last_seen_at']}');
    if (lastSeen != null &&
        DateTime.now().difference(lastSeen) > const Duration(minutes: 2) &&
        !['paused', 'read_disabled', 'scope_required', 'not_created']
            .contains(state)) {
      state = 'offline';
    }
    final label = !verified
        ? '尚未核验'
        : !supported
            ? '服务端尚未提供运行状态'
            : labels[state] ?? '尚未核验';
    String date(dynamic value) {
      final time = DateTime.tryParse('$value')?.toLocal();
      if (time == null) return '暂无记录';
      return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }

    final action = runtime['last_action'];
    return [
      _BotCondition(
          icon: state == 'loading' ? Icons.sync : Icons.smart_toy_outlined,
          text: '后台运行：$label'),
      if (supported && verified) ...[
        if (state == 'scope_required')
          const Text(
              '绑定只建立连接，后台浏览还需要你批准「公开社区浏览」；已有的「本人公开帖子」是另一项权限，不能代替它。在原聊天发送 /sylu-connect 获取补充授权链接，勾选公开浏览并确认替换原连接；无需先解绑，也不需要成绩、二课或签到权限。'),
        const SizedBox(height: AppSpacing.sm),
        Text('最近浏览：${date(runtime['last_read_at'])}',
            style: Theme.of(context).textTheme.bodySmall),
        if (runtime['next_run_at'] != null &&
            ![
              'offline',
              'paused',
              'read_disabled',
              'scope_required',
              'disabled',
              'syncing'
            ].contains(state))
          Text('下次计划：${date(runtime['next_run_at'])}',
              style: Theme.of(context).textTheme.bodySmall),
        Text(
            action is Map
                ? '最近发言：${action['kind'] == 'post' ? '帖子' : '评论'} · ${date(action['completed_at'])}'
                : '最近发言：暂无成功记录',
            style: Theme.of(context).textTheme.bodySmall),
        if (state == 'error')
          Text(
              runtime['error_code'] == 'provider_required'
                  ? '执行端尚未配置浏览模型，请联系部署者。'
                  : '本轮未完成，执行端将按间隔重新检查。',
              style: Theme.of(context).textTheme.bodySmall),
      ],
      if (supported)
        TextButton.icon(
            key: const ValueKey('bot-refresh-runtime'),
            style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                visualDensity: VisualDensity.standard),
            onPressed: _loading || _busy || _runtimeRefreshing
                ? null
                : _refreshRuntime,
            icon: const Icon(Icons.refresh),
            label: Text(_runtimeRefreshing ? '正在核验运行状态…' : '刷新运行状态')),
      const SizedBox(height: AppSpacing.md),
    ];
  }

  Widget _privacy(BuildContext context) => _BotSurface(
      surfaceKey: const ValueKey('bot-privacy-surface'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BotDisclosure(
              disclosureKey: const ValueKey('bot-privacy-toggle'),
              title: '记忆与隐私',
              subtitle: '群聊不入长期记忆，私聊与公开阅读隔离',
              expanded: _privacyExpanded,
              onTap: () =>
                  setState(() => _privacyExpanded = !_privacyExpanded)),
          if (_privacyExpanded) ...[
            const SizedBox(height: AppSpacing.lg),
            const _BotPolicy(
                icon: Icons.groups_outlined,
                title: '群聊',
                description: '群聊仅保留短期上下文，不写长期记忆。'),
            const AppCardDivider(height: AppSpacing.xxl),
            const _BotPolicy(
                icon: Icons.lock_person_outlined,
                title: '创建者私聊',
                description: '只在本人私聊中检索，正文在 AstrBot 本机加密保存。'),
            const AppCardDivider(height: AppSpacing.xxl),
            const _BotPolicy(
                icon: Icons.public,
                title: '公开社区',
                description: '阅读内容单独记忆；自动评论不能读取私人记忆、账号资料或登录态。'),
            const AppCardDivider(height: AppSpacing.xxl),
            const _BotPolicy(
                icon: Icons.shield_outlined,
                title: '平台规则始终生效',
                description: '机器人发言仍受社区审核、禁言和举报管理。顶层评论每帖一次；可回复新的真人评论，每个目标一次，所有回复共享每日额度与间隔。用户设置只能收紧平台限制。'),
            const SizedBox(height: AppSpacing.lg),
            Text('清除记忆与模型在你部署的 AstrBot 管理。原始聊天和模型服务副本有各自的保存规则。',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ));

  ButtonStyle _primaryStyle(BuildContext context) => FilledButton.styleFrom(
      visualDensity: VisualDensity.standard,
      minimumSize: const Size(44, 48),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      textStyle: Theme.of(context).textTheme.labelLarge);
  ButtonStyle _secondaryStyle(BuildContext context) => OutlinedButton.styleFrom(
      visualDensity: VisualDensity.standard,
      minimumSize: const Size(44, 48),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      textStyle: Theme.of(context).textTheme.labelLarge);
  InputDecoration _input(String label, {String? helper}) => InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md)));
}

class _BotSurface extends StatelessWidget {
  const _BotSurface({required this.surfaceKey, required this.child});
  final Key surfaceKey;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AppCardSurface(
        key: surfaceKey,
        padding: const EdgeInsets.all(AppSpacing.lg),
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

class _BotCapabilityControl extends StatelessWidget {
  const _BotCapabilityControl(
      {required this.controlKey,
      required this.title,
      required this.description,
      required this.icon,
      required this.selected,
      required this.enabled,
      required this.onChanged});
  final Key controlKey;
  final String title, description;
  final IconData icon;
  final bool selected, enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
        key: controlKey,
        button: true,
        toggled: selected,
        enabled: enabled,
        child: Material(
            type: MaterialType.transparency,
            child: Ink(
              decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: enabled ? .08 : .04)
                      : Colors.transparent,
                  border: Border.all(
                      color: selected && enabled
                          ? scheme.primary
                          : scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(AppRadius.md)),
              child: InkWell(
                onTap: enabled ? () => onChanged(!selected) : null,
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 112),
                  child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(icon,
                                  size: 20,
                                  color: enabled
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant),
                              const Spacer(),
                              Icon(
                                  selected
                                      ? Icons.check_circle_outline
                                      : Icons.circle_outlined,
                                  size: 20,
                                  color: selected && enabled
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant)
                            ]),
                            const SizedBox(height: AppSpacing.sm),
                            Text(title, style: text.titleSmall),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                                selected
                                    ? enabled
                                        ? '已选择'
                                        : '已保留'
                                    : '未选择',
                                style: text.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                            const SizedBox(height: AppSpacing.sm),
                            Text(description, style: text.bodySmall),
                          ])),
                ),
              ),
            )));
  }
}

class _BotDisclosure extends StatelessWidget {
  const _BotDisclosure(
      {required this.disclosureKey,
      required this.title,
      required this.expanded,
      required this.onTap,
      this.subtitle});
  final Key disclosureKey;
  final String title;
  final String? subtitle;
  final bool expanded;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
        expanded: expanded,
        button: true,
        child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: disclosureKey,
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(children: [
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(title, style: text.titleSmall),
                            if (subtitle != null) ...[
                              const SizedBox(height: AppSpacing.xs),
                              Text(subtitle!,
                                  style: text.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                            ],
                          ])),
                      const SizedBox(width: AppSpacing.sm),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more,
                          size: 22),
                    ]),
                  )),
            )));
  }
}

class _BotCondition extends StatelessWidget {
  const _BotCondition(
      {required this.icon, required this.text, this.success = false});
  final IconData icon;
  final String text;
  final bool success;
  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon,
            size: 20,
            color: success
                ? AppColors.success
                : Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
      ]);
}

class _BotPolicy extends StatelessWidget {
  const _BotPolicy(
      {required this.icon, required this.title, required this.description});
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
        const SizedBox(width: AppSpacing.md),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(description, style: Theme.of(context).textTheme.bodyMedium),
        ])),
      ]);
}

class _BotFeedback extends StatelessWidget {
  const _BotFeedback({required this.message, this.error = false, this.action});
  final String message;
  final bool error;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      child: _BotSurface(
          surfaceKey:
              ValueKey(error ? 'bot-error-surface' : 'bot-notice-surface'),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(error ? Icons.error_outline : Icons.check_circle_outline,
                  color: error
                      ? Theme.of(context).colorScheme.error
                      : AppColors.success,
                  size: 22),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                  child: Text(message,
                      style: Theme.of(context).textTheme.bodyMedium)),
            ]),
            if (action != null)
              Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: action),
          ])));
}
