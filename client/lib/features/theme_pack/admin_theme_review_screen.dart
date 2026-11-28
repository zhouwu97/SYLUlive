import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/publish_session_scope.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/security_session_guard.dart';
import 'theme_appearance.dart';
import 'theme_manifest.dart';
import 'theme_pack_codec.dart';
import 'theme_store_repository.dart';
import 'theme_workshop_samples.dart';

class AdminThemeReviewScreen extends StatefulWidget {
  const AdminThemeReviewScreen({
    super.key,
    this.repository,
  });

  final ThemeStoreRepository? repository;

  @override
  State<AdminThemeReviewScreen> createState() => _AdminThemeReviewScreenState();
}

class _AdminThemeReviewScreenState extends State<AdminThemeReviewScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<ThemeSubmissionItem> _pending = const [];
  List<ThemeSubmissionItem> _approved = const [];
  bool _loading = false;
  bool _busy = false;
  String? _error;

  int? _observedUserId;
  int? _observedEpoch;
  String? _observedRole;
  PublishSessionScope? _session;
  int _loadGeneration = 0;
  CancelToken? _cancelToken;

  ThemeStoreRepository _repo(AuthProvider auth) =>
      widget.repository ?? ThemeStoreRepository(auth.dio);

  bool _ownsSession(AuthProvider auth, PublishSessionScope? session) =>
      mounted &&
      session != null &&
      SecuritySessionGuard.owns(auth, session, requireAdmin: true);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedUserId == auth.user?.id &&
        _observedEpoch == auth.accountSessionEpoch &&
        _observedRole == auth.user?.role) {
      return;
    }
    _observedUserId = auth.user?.id;
    _observedEpoch = auth.accountSessionEpoch;
    _observedRole = auth.user?.role;
    _cancelToken?.cancel('管理员会话变化');
    _loadGeneration++;
    _pending = const [];
    _approved = const [];
    _error = null;
    _session = auth.isLoggedIn && auth.user?.isAdmin == true
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch,
          )
        : null;
    if (_session != null) {
      unawaited(_load());
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('页面关闭');
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (!_ownsSession(auth, session)) return;
    final generation = ++_loadGeneration;
    _cancelToken?.cancel('刷新');
    final token = CancelToken();
    _cancelToken = token;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = _repo(auth);
      final results = await Future.wait([
        repo.adminList(
            session: session!, status: 'pending', cancelToken: token),
        repo.adminList(
            session: session, status: 'approved', cancelToken: token),
      ]);
      if (!mounted ||
          token.isCancelled ||
          generation != _loadGeneration ||
          !_ownsSession(auth, session)) {
        return;
      }
      setState(() {
        _pending = results[0];
        _approved = results[1];
      });
    } catch (e) {
      if (!mounted ||
          token.isCancelled ||
          generation != _loadGeneration ||
          !_ownsSession(auth, session)) {
        return;
      }
      setState(() => _error = '加载主题审核列表失败，请重试');
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openDetail(ThemeSubmissionItem item) async {
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (!_ownsSession(auth, session)) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SecuritySessionGuard(
          auth: auth,
          session: session!,
          requireAdmin: true,
          child: AdminThemeReviewDetailScreen(
            submission: item,
            repository: widget.repository,
          ),
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  Future<void> _removePublished(ThemeSubmissionItem item) async {
    if (_busy) return;
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (!_ownsSession(auth, session)) return;

    final decision = await showThemeReasonDialog(
      context,
      title: '下架《${item.name}》',
      confirmLabel: '确认下架',
    );
    if (decision == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await _repo(auth).adminRemove(
        item.familyId,
        reasonCode: decision.$1,
        note: decision.$2,
        session: session!,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已下架《${item.name}》')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final authorized = _ownsSession(auth, _session);

    return Scaffold(
      appBar: AppBar(
        title: const Text('主题审核'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '待审核 (${_pending.length})'),
            Tab(text: '已上架 (${_approved.length})'),
          ],
        ),
      ),
      body: !authorized
          ? const Center(child: Text('需要有效的管理员会话才能操作主题审核'))
          : _loading && _pending.isEmpty && _approved.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _pending.isEmpty && _approved.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        RefreshIndicator(
                          onRefresh: _load,
                          child: _buildPendingList(),
                        ),
                        RefreshIndicator(
                          onRefresh: _load,
                          child: _buildApprovedList(),
                        ),
                      ],
                    ),
    );
  }

  Widget _buildPendingList() {
    if (_pending.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          Center(child: Text('当前没有待审核的主题投稿')),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(14),
      itemCount: _pending.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _pending[index];
        final tokens = AppThemeTokens.of(context);
        final colors = Theme.of(context).colorScheme;
        return AppCard(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openDetail(item),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ReviewAvatar(name: item.name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item.name} · v${item.version}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (item.source == 'official')
                              _ReviewTag(
                                label: '官方',
                                icon: Icons.verified_rounded,
                                color: colors.primary,
                              ),
                            _ReviewTag(
                              label: item.currentApproved == null
                                  ? '新作品'
                                  : '更新自 v${item.currentApproved!.version}',
                              icon: item.currentApproved == null
                                  ? Icons.auto_awesome_outlined
                                  : Icons.history_rounded,
                              color: tokens.textSecondary,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${item.author?.nickname ?? 'UID ${item.authorUserId}'} · ${ThemeReviewReasons.formatBytes(item.packageSize)} · ${item.license}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.textSecondary,
                          ),
                        ),
                        if (item.description.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, height: 1.45),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: tokens.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildApprovedList() {
    if (_approved.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          Center(child: Text('当前没有已上架主题')),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(14),
      itemCount: _approved.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _approved[index];
        final tokens = AppThemeTokens.of(context);
        final colors = Theme.of(context).colorScheme;
        return AppCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                _ReviewAvatar(name: item.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item.name} · v${item.version}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${item.author?.nickname ?? 'UID ${item.authorUserId}'} · ${item.source == 'official' ? '官方' : '社区'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                  onPressed: _busy ? null : () => _removePublished(item),
                  child: const Text('下架'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReviewAvatar extends StatelessWidget {
  const _ReviewAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first;
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: colors.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _ReviewTag extends StatelessWidget {
  const _ReviewTag({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

Future<(String, String)?> showThemeReasonDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
}) {
  String? selectedCode;
  final noteController = TextEditingController();
  return showAppDialog<(String, String)>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dialogCtx, setDialogState) => AppAlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '必须选择一项原因代码（作者可见对应中文说明）：',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              for (final opt in ThemeReviewReasons.options)
                ListTile(
                  key: ValueKey('theme-reason-${opt.$1}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    selectedCode == opt.$1
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: selectedCode == opt.$1
                        ? Theme.of(dialogCtx).colorScheme.primary
                        : null,
                  ),
                  onTap: () => setDialogState(() => selectedCode = opt.$1),
                  title: Text(
                    '${opt.$1}：${opt.$2}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('theme-reason-note'),
                controller: noteController,
                maxLength: 200,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '补充说明（可选）',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('admin-theme-confirm-reject'),
            onPressed: selectedCode == null
                ? null
                : () => Navigator.of(dialogCtx).pop(
                      (selectedCode!, noteController.text.trim()),
                    ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
}

class AdminThemeReviewDetailScreen extends StatefulWidget {
  const AdminThemeReviewDetailScreen({
    super.key,
    required this.submission,
    this.repository,
    this.appVersion,
  });

  final ThemeSubmissionItem submission;
  final ThemeStoreRepository? repository;
  final String? appVersion;

  @override
  State<AdminThemeReviewDetailScreen> createState() =>
      _AdminThemeReviewDetailScreenState();
}

class _AdminThemeReviewDetailScreenState
    extends State<AdminThemeReviewDetailScreen> {
  PreparedThemePack? _loadedPack;
  Uint8List? _lightPreviewBytes;
  Uint8List? _darkPreviewBytes;
  bool _loadingTrial = false;
  bool _submittingDecision = false;
  String? _error;

  PublishSessionScope? _session;
  int? _observedUserId;
  int? _observedEpoch;
  String? _observedRole;
  bool _startedPrivateTrialHere = false;
  CancelToken? _cancelToken;

  ThemeStoreRepository _repo(AuthProvider auth) =>
      widget.repository ?? ThemeStoreRepository(auth.dio);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedUserId == auth.user?.id &&
        _observedEpoch == auth.accountSessionEpoch &&
        _observedRole == auth.user?.role) {
      return;
    }
    final hadSession = _session != null;
    _observedUserId = auth.user?.id;
    _observedEpoch = auth.accountSessionEpoch;
    _observedRole = auth.user?.role;
    final validAdmin = auth.isLoggedIn && auth.user?.isAdmin == true;
    if (hadSession) {
      // 管理员切号、退出或权限撤回时立即终止私有包试用并清理临时目录。
      _cancelToken?.cancel('会话已变更');
      if (_startedPrivateTrialHere) {
        _startedPrivateTrialHere = false;
        final tp = context.read<ThemeProvider?>();
        if (tp != null) unawaited(tp.endTrial());
      }
      _session = null;
      return;
    }
    if (validAdmin) {
      _session = PublishSessionScope(
        accountId: auth.user!.id,
        accountSessionEpoch: auth.accountSessionEpoch,
      );
      unawaited(_loadPrivatePreviews());
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('离开审核详情');
    super.dispose();
  }

  Future<void> _loadPrivatePreviews() async {
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (session == null) return;
    final repo = _repo(auth);
    final tok = CancelToken();
    _cancelToken = tok;

    Future<Uint8List?> fetchImg(String urlPath) async {
      if (urlPath.isEmpty) return null;
      try {
        final resp = await repo.dio.getUri<List<int>>(
          Uri.parse(repo.resolveUrl(urlPath)),
          cancelToken: tok,
          options: Options(
            responseType: ResponseType.bytes,
            extra: session.requestExtra,
          ),
        );
        return resp.data == null ? null : Uint8List.fromList(resp.data!);
      } catch (_) {
        return null;
      }
    }

    final imgs = await Future.wait([
      fetchImg(widget.submission.previewLight),
      fetchImg(widget.submission.previewDark),
    ]);
    if (!mounted || tok.isCancelled) return;
    setState(() {
      _lightPreviewBytes = imgs[0];
      _darkPreviewBytes = imgs[1];
    });
  }

  Future<String> _resolveAppVersion() async {
    if (widget.appVersion != null) return widget.appVersion!;
    try {
      return (await PackageInfo.fromPlatform())
          .version
          .split('+')
          .first
          .split('-')
          .first;
    } catch (_) {
      return '1.0.0';
    }
  }

  Future<void> _startPrivateTrial() async {
    if (_loadingTrial || _submittingDecision) return;
    final auth = context.read<AuthProvider>();
    final provider = context.read<ThemeProvider>();
    final session = _session;
    if (session == null ||
        !SecuritySessionGuard.owns(auth, session, requireAdmin: true)) {
      return;
    }
    setState(() {
      _loadingTrial = true;
      _error = null;
    });
    try {
      final repo = _repo(auth);
      final downloader = ThemePackDownloadManager.shared(
        provider.themePacks,
        repo,
      );
      final ver = await _resolveAppVersion();
      final prepared = _loadedPack ??
          await downloader.downloadPrivatePack(
            submission: widget.submission,
            appVersion: ver,
            session: session,
          );
      if (!mounted ||
          !SecuritySessionGuard.owns(auth, session, requireAdmin: true)) {
        return;
      }
      _loadedPack = prepared;
      await provider.startTrial(
        pack: prepared,
        groups: ThemeGroup.applicable,
      );
      _startedPrivateTrialHere = true;
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已开启跨页面试用，可返回各页签检查效果，顶部横条可随时结束'),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '加载私有待审主题包失败：$e');
    } finally {
      if (mounted) setState(() => _loadingTrial = false);
    }
  }

  Future<void> _submitReview({
    required bool approve,
    String reasonCode = '',
    String note = '',
  }) async {
    if (_submittingDecision) return;
    final auth = context.read<AuthProvider>();
    final session = _session;
    if (session == null ||
        !SecuritySessionGuard.owns(auth, session, requireAdmin: true)) {
      return;
    }
    setState(() {
      _submittingDecision = true;
      _error = null;
    });
    try {
      await _repo(auth).adminReview(
        widget.submission.id,
        approve: approve,
        reasonCode: reasonCode,
        note: note,
        session: session,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(approve ? '已审核通过并上架' : '已拒绝该主题投稿'),
        ),
      );
      unawaited(Navigator.of(context).maybePop(true));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submittingDecision = false);
    }
  }

  Future<void> _handleRejectPressed() async {
    final result = await showThemeReasonDialog(
      context,
      title: '拒绝《${widget.submission.name}》',
      confirmLabel: '确认拒绝',
    );
    if (result == null || !mounted) return;
    await _submitReview(
      approve: false,
      reasonCode: result.$1,
      note: result.$2,
    );
  }

  List<String> _computeDiffLines(
    Map<String, dynamic>? current,
    Map<String, dynamic>? previous,
  ) {
    if (current == null || previous == null) return const [];
    final diffs = <String>[];
    for (final key in [
      'name',
      'description',
      'license',
      'minAppVersion',
      'shape'
    ]) {
      if ('${current[key]}' != '${previous[key]}') {
        final label = const {
          'name': '主题名称',
          'description': '主题简介',
          'license': '使用许可',
          'minAppVersion': '适用版本',
          'shape': '圆角风格',
        }[key]!;
        diffs.add('$label已更新');
      }
    }
    if (jsonEncode(current['layout']) != jsonEncode(previous['layout'])) {
      diffs.add('页头布局模板参数已变更');
    }
    if (jsonEncode(current['font']) != jsonEncode(previous['font'])) {
      diffs.add('自定义字体声明已变更');
    }
    if (jsonEncode(current['launcherIcon']) !=
        jsonEncode(previous['launcherIcon'])) {
      diffs.add('桌面图标声明已变更');
    }
    for (final mode in ['light', 'dark']) {
      final curTokens = (current[mode] as Map?)?['tokens'] as Map? ?? const {};
      final prevTokens =
          (previous[mode] as Map?)?['tokens'] as Map? ?? const {};
      var changedTokens = 0;
      for (final tk in curTokens.keys) {
        if (curTokens[tk] != prevTokens[tk]) changedTokens++;
      }
      if (changedTokens > 0) {
        diffs.add('${mode == "dark" ? "深色" : "浅色"}模式调整了 $changedTokens 处配色');
      }
      if (jsonEncode((current[mode] as Map?)?['decorations']) !=
          jsonEncode((previous[mode] as Map?)?['decorations'])) {
        diffs.add('${mode == "dark" ? "深色" : "浅色"}页头装饰背景或贴纸已变更');
      }
    }
    if (diffs.isEmpty) diffs.add('参数与上一版一致，仅重打包或更新预览资源');
    return diffs;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider?>();
    final sub = widget.submission;
    final manifestMap = sub.manifest ?? _loadedPack?.manifest.data;
    final storedManifest =
        manifestMap != null ? ThemeManifest.fromStored(manifestMap) : null;
    final isTrialingThis = provider?.isInTrial == true &&
        provider?.trial?.manifest.id == sub.familyId &&
        provider?.trial?.manifest.version == sub.version;

    final fontMap = manifestMap?['font'] as Map?;
    final launcherMap = manifestMap?['launcherIcon'] as Map?;
    final layoutMap = manifestMap?['layout'] as Map?;

    return Scaffold(
      appBar: AppBar(
        title: Text('审核《${sub.name}》v${sub.version}'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              // 试用状态与操作卡
              AppCard(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(
                        isTrialingThis
                            ? Icons.visibility_rounded
                            : Icons.visibility_outlined,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isTrialingThis ? '正在试用，可返回各页面查看效果' : '先试用，看看实际效果',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isTrialingThis)
                        OutlinedButton(
                          onPressed: () => provider?.endTrial(),
                          child: const Text('结束试用'),
                        )
                      else
                        FilledButton.tonalIcon(
                          key: const ValueKey('admin-theme-start-trial'),
                          onPressed: _loadingTrial ? null : _startPrivateTrial,
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: Text(_loadingTrial ? '下载中…' : '试用此主题'),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 明暗预览图
              AppCard(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${sub.name} · v${sub.version} (${sub.source == "official" ? "官方" : "社区"})',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '作者：${sub.author?.nickname ?? "用户 ${sub.authorUserId}"} · ${ThemeReviewReasons.formatBytes(sub.packageSize)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        '${ThemeReviewReasons.licenseLabel(sub.license)} · 适用于 ${sub.minAppVersion} 及以上版本',
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (sub.tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final tag in sub.tags)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text(tag),
                              ),
                          ],
                        ),
                      ],
                      if (sub.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(sub.description),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _PreviewBox(
                              label: '浅色预览',
                              bytes: _lightPreviewBytes,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _PreviewBox(
                              label: '深色预览',
                              bytes: _darkPreviewBytes,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 与上一版的对比
              if (sub.currentApproved != null) ...[
                AppCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '与当前已上架版本 v${sub.currentApproved!.version} 的对比',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        for (final line in _computeDiffLines(
                          manifestMap,
                          sub.currentApproved!.manifest,
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text('• $line',
                                style: const TextStyle(fontSize: 12.5)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 布局、卡片样式、图片效果与装饰层次
              if (manifestMap != null) ...[
                AppCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '主题效果',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '圆角：${const {
                            'compact': '小圆角',
                            'standard': '标准圆角',
                            'rounded': '大圆角'
                          }[manifestMap['shape'] ?? 'standard']}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        for (final page in const ['home', 'campus', 'me'])
                          Text(
                            '${_pageLabel(page)}页头：${const {
                              'standard': '图文分区',
                              'compact': '紧凑排列',
                              'immersive': '沉浸插画'
                            }[(layoutMap?[page] as Map?)?['preset'] ?? 'standard']}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        for (final mode in ['light', 'dark']) ...[
                          const SizedBox(height: 6),
                          _VariantInspectionSection(
                            modeLabel: mode == 'dark' ? '深色' : '浅色',
                            variant: Map<String, dynamic>.from(
                              manifestMap[mode] as Map,
                            ),
                            loadedContents: _loadedPack?.contents,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 字体与版权说明
              if (fontMap != null ||
                  sub.fontCopyright.isNotEmpty ||
                  sub.fontLicenseNote.isNotEmpty) ...[
                AppCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '字体与版权核验',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        if (fontMap != null)
                          Text(
                            '声明名称：${fontMap['name']} · 声明许可：${fontMap['license']} · 文件：${fontMap['regular']}${fontMap['bold'] != null ? " / ${fontMap['bold']}" : ""}',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        Text(
                          'SFNT nameID 0 版权：${sub.fontCopyright.isEmpty ? "（未内嵌）" : sub.fontCopyright}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        Text(
                          'SFNT nameID 13 许可说明：${sub.fontLicenseNote.isEmpty ? "（未内嵌）" : sub.fontLicenseNote}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 桌面图标
              if (launcherMap != null) ...[
                AppCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '桌面图标声明',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '内置图标 ID：${launcherMap['builtin'] ?? "无"} · 自定义快捷方式图片：${launcherMap['custom'] ?? "无"}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        if (launcherMap['custom'] != null &&
                            _loadedPack?.contents[launcherMap['custom']] !=
                                null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.memory(
                                _loadedPack!.contents[launcherMap['custom']]!,
                                width: 72,
                                height: 72,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 桌面小部件明暗预览
              if (storedManifest != null) ...[
                AppCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '桌面小部件双色映射预览',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        ThemeWorkshopWidgetPreviewPanel(
                          appearance: const ThemeAppearance.empty().apply(
                            storedManifest,
                            ThemeGroup.applicable
                                .intersection(storedManifest.groups),
                            '',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // 审核判定按钮栏
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('admin-theme-reject-button'),
                      onPressed:
                          _submittingDecision ? null : _handleRejectPressed,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('拒绝（必选原因）'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('admin-theme-approve-button'),
                      onPressed: _submittingDecision
                          ? null
                          : () => _submitReview(approve: true),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(_submittingDecision ? '提交中…' : '审核通过'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.label, required this.bytes});
  final String label;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1080 / 2340,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: bytes == null
                ? Container(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.image_outlined)),
                  )
                : Image.memory(bytes!, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

String _pageLabel(String page) =>
    const {
      'global': '全局',
      'home': '首页',
      'campus': '校园',
      'me': '我的',
      'schedule': '课表',
      'secondary': '其他页面',
    }[page] ??
    page;

String _imageEffects(Map settings) {
  final adjustments = settings['adjustments'] as Map?;
  final brightness = (adjustments?['brightness'] as num?) ?? 0;
  final contrast = (adjustments?['contrast'] as num?) ?? 100;
  final saturation = (adjustments?['saturation'] as num?) ?? 100;
  final blur = (settings['blur'] as num?) ?? 0;
  final scrim = (settings['scrim'] as num?) ?? 0;
  final effects = [
    if (brightness != 0)
      '亮度${brightness > 0 ? '提高' : '降低'} ${brightness.abs().round()}',
    if (contrast != 100) '对比度 ${contrast.round()}%',
    if (saturation != 100) '饱和度 ${saturation.round()}%',
    if (blur > 0) '背景虚化',
    if (scrim > 0) '遮罩 ${(scrim * 100).round()}%',
  ];
  return effects.isEmpty ? '保留原图效果' : effects.join('、');
}

class _VariantInspectionSection extends StatelessWidget {
  const _VariantInspectionSection({
    required this.modeLabel,
    required this.variant,
    required this.loadedContents,
  });

  final String modeLabel;
  final Map<String, dynamic> variant;
  final Map<String, Uint8List>? loadedContents;

  @override
  Widget build(BuildContext context) {
    final cs = variant['cardStyle'] as Map?;
    final decos = variant['decorations'] as Map?;
    final walls = variant['wallpapers'] as Map?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$modeLabel模式',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        Text(
          '卡片：${const {
            'solid': '纯色底',
            'tint': '淡彩底',
            'glass': '玻璃效果'
          }[cs?['fill'] ?? 'solid']} · ${const {
            'none': '无阴影',
            'soft': '柔和阴影',
            'medium': '明显阴影'
          }[cs?['shadow'] ?? 'soft']} · 不透明度 ${(((variant['componentOpacity'] as num?) ?? 1) * 100).round()}%',
          style: const TextStyle(fontSize: 12),
        ),
        if (cs?['borderWidth'] != null)
          Text(
            (cs!['borderWidth'] as num) == 0
                ? '卡片边缘：无描边'
                : '卡片边缘：${cs['borderWidth']} 宽描边',
            style: const TextStyle(fontSize: 12),
          ),
        if (walls != null)
          for (final e in walls.entries)
            if (e.value is Map)
              Text(
                '${_pageLabel(e.key as String)}背景：主题壁纸 · ${_imageEffects(e.value as Map)}',
                style: const TextStyle(fontSize: 11.5),
              ),
        if (decos != null)
          for (final e in decos.entries)
            if (e.value is Map) ...[
              if ((e.value as Map)['background'] is Map)
                Text(
                  '${_pageLabel(e.key as String)}页头插画：${_imageEffects((e.value as Map)['background'] as Map)}',
                  style: const TextStyle(fontSize: 11.5),
                ),
              for (var i = 0;
                  i < (((e.value as Map)['stickers'] as List?)?.length ?? 0);
                  i++)
                Builder(
                  builder: (_) {
                    final st = ((e.value as Map)['stickers'] as List)[i] as Map;
                    final imgPath = st['image'] as String? ?? '';
                    final mem = loadedContents?[imgPath];
                    return Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          if (mem != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Image.memory(mem, width: 24, height: 24),
                            ),
                          Expanded(
                            child: Text(
                              '${_pageLabel(e.key as String)}贴纸 ${i + 1}：横向 ${((st['x'] as num) * 100).round()}%、纵向 ${((st['y'] as num) * 100).round()}%，宽度 ${((st['width'] as num) * 100).round()}%，旋转 ${st['rotation']}°',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
      ],
    );
  }
}
