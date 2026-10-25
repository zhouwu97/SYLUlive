import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../config/api_constants.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/emoji/sticker_catalog.dart';
import '../application/emoji_pack_download_manager.dart';
import '../application/emoji_recent_manager.dart';
import '../data/emoji_pack_catalog_repository.dart';
import '../data/emoji_pack_local_store.dart';
import '../domain/emoji_pack_installation.dart';
import '../domain/emoji_pack_manifest.dart';
import 'emoji_ui.dart';

String _assetUrl(EmojiPackCatalogRepository catalog, EmojiCatalogEntry entry,
    EmojiManifestAsset asset) {
  final base = catalog.dio.options.baseUrl;
  return Uri.parse(base.endsWith('/') ? base : '$base/')
      .resolve(
          'emoji/packs/${Uri.encodeComponent(entry.id)}/assets/${Uri.encodeComponent(asset.id)}')
      .replace(queryParameters: {'version': '${entry.version}'}).toString();
}

class EmojiDownloadScreen extends StatefulWidget {
  const EmojiDownloadScreen(
      {super.key,
      required this.store,
      this.repository,
      this.initialPackId,
      this.recentManager});
  final EmojiPackLocalStore store;
  final EmojiPackCatalogRepository? repository;
  final String? initialPackId;
  final EmojiRecentManager? recentManager;

  @override
  State<EmojiDownloadScreen> createState() => _EmojiDownloadScreenState();
}

class _EmojiDownloadScreenState extends State<EmojiDownloadScreen> {
  late final EmojiPackCatalogRepository _catalog;
  late final EmojiPackDownloadManager _manager;
  late final EmojiRecentManager _recentManager;
  late final String? _account;
  List<EmojiCatalogEntry>? _entries;
  Map<String, EmojiPackInstallation> _installed = {};
  final Set<EmojiDownloadTask> _completed = {};
  Object? _error;
  int _generation = 0;
  int _installedGeneration = 0;
  bool _initialPreviewOpened = false;
  bool _sessionInvalid = false;
  bool get _current =>
      mounted && !_sessionInvalid && _account == _recentManager.userId;

  @override
  void initState() {
    super.initState();
    _recentManager = widget.recentManager ?? EmojiRecentManager.instance;
    _account = _recentManager.userId;
    _catalog = widget.repository ??
        EmojiPackCatalogRepository(Dio(BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 30))));
    _manager = EmojiPackDownloadManager.shared(widget.store, _catalog)
      ..addListener(_changed);
    _recentManager.addListener(_sessionChanged);
    unawaited(_load());
  }

  void _sessionChanged() {
    if (_account == _recentManager.userId) return;
    _sessionInvalid = true;
    _generation++;
    _installedGeneration++;
    for (final id in _manager.tasks.keys) {
      _manager.pause(id);
    }
    if (!mounted) return;
    setState(() {
      _entries = null;
      _installed = {};
    });
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
  }

  void _changed() {
    if (!_current) return;
    for (final task in _manager.tasks.values) {
      if (task.status == EmojiDownloadStatus.installed &&
          _completed.add(task)) {
        unawaited(_reloadInstalled());
      }
    }
    setState(() {});
  }

  Future<void> _reloadInstalled() async {
    final generation = ++_installedGeneration;
    try {
      final installed = await widget.store.load();
      if (!_current || generation != _installedGeneration) return;
      setState(
          () => _installed = {for (final item in installed) item.packId: item});
    } catch (_) {
      if (_current && generation == _installedGeneration) {
        setState(() => _error = StateError('本机安装状态读取失败'));
      }
    }
  }

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_generation;
    try {
      await _manager.restore();
      if (!_current || generation != _generation) return;
      await _reloadInstalled();
      if (!_current || generation != _generation) return;
      final entries = (await _catalog.list())
          .where((entry) => entry.id != appStickerGroups.first.id)
          .toList(growable: false);
      if (!_current || generation != _generation) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
      if (!_initialPreviewOpened && widget.initialPackId != null) {
        _initialPreviewOpened = true;
        final matches =
            entries.where((entry) => entry.id == widget.initialPackId);
        if (matches.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_current) unawaited(_openPreview(matches.first));
          });
        }
      }
    } catch (error) {
      if (_current && generation == _generation) setState(() => _error = error);
    }
  }

  Future<void> _openPreview(EmojiCatalogEntry entry) async {
    if (!_current) return;
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => EmojiPackPreviewScreen(
            entry: entry,
            catalog: _catalog,
            manager: _manager,
            installation: _installed[entry.id],
            recentManager: _recentManager)));
    if (!_current) return;
    await _reloadInstalled();
    if (!mounted || !_current) return;
    if (result != null) Navigator.of(context).pop(result);
  }

  @override
  void dispose() {
    _recentManager.removeListener(_sessionChanged);
    _manager.removeListener(_changed);
    for (final id in _manager.tasks.keys) {
      _manager.pause(id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EmojiPageScaffold(
      title: '官方表情',
      body: !_current
          ? const EmojiStateView(title: '账号已切换，请返回')
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  const EmojiSectionHeader(
                      title: '添加喜欢的表情', detail: '先预览内容，再下载到本机。'),
                  if (_error != null)
                    EmojiInlineError(
                        message: '官方目录暂不可用，已有表情仍可使用', onRetry: _load),
                  if (_entries == null && _error == null)
                    const Padding(
                        padding: EdgeInsets.all(AppSpacing.xxl),
                        child: Center(child: CircularProgressIndicator()))
                  else if (_entries?.isEmpty == true)
                    const EmojiStateView(title: '暂无可下载的官方表情', detail: '稍后再来看看。')
                  else
                    for (final entry in _entries ?? <EmojiCatalogEntry>[])
                      _tile(entry),
                ],
              )));

  Widget _tile(EmojiCatalogEntry entry) {
    final task = _manager.tasks[entry.id], installation = _installed[entry.id];
    final downloading = task?.status == EmojiDownloadStatus.downloading;
    final installing = task?.status == EmojiDownloadStatus.installing;
    final damaged = installation?.status == EmojiPackInstallStatus.damaged;
    final installed = !damaged && installation?.version == entry.version;
    final status = downloading
        ? '正在下载'
        : installing
            ? '正在校验并安装'
            : damaged
                ? '本机文件需要修复'
                : installed
                    ? '已安装${installation!.enabled ? '' : ' · 已停用'}'
                    : installation == null
                        ? '可下载'
                        : '可更新';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EmojiPackRow(
          name: entry.name,
          detail:
              '${entry.assetCount} 个表情 · ${emojiBytesLabel(entry.totalSize)}',
          status: status,
          damaged: damaged,
          statusIcon: damaged
              ? Icons.error_outline
              : installed
                  ? Icons.check_circle_outline
                  : Icons.download_outlined,
          cover: _CatalogCover(
              key: ValueKey('${entry.id}:${entry.version}:$_generation'),
              catalog: _catalog,
              entry: entry),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_openPreview(entry))),
      if (downloading || installing)
        Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: LinearProgressIndicator(
                value: installing || entry.totalSize == 0
                    ? null
                    : (task!.receivedBytes / entry.totalSize).clamp(0, 1))),
      if (task?.status == EmojiDownloadStatus.paused)
        Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text('已暂停 · 继续下载可保留进度',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: emojiMuted(context)))),
      if (task?.error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(task!.error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error))),
      Divider(height: 1, color: emojiBorder(context)),
    ]);
  }
}

class _CatalogCover extends StatefulWidget {
  const _CatalogCover({super.key, required this.catalog, required this.entry});
  final EmojiPackCatalogRepository catalog;
  final EmojiCatalogEntry entry;
  @override
  State<_CatalogCover> createState() => _CatalogCoverState();
}

class _CatalogCoverState extends State<_CatalogCover> {
  final CancelToken _token = CancelToken();
  late final Future<EmojiPackManifest> _manifest;
  @override
  void initState() {
    super.initState();
    _manifest = widget.catalog.manifest(widget.entry, _token);
  }

  @override
  void dispose() {
    _token.cancel('封面已离开');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<EmojiPackManifest>(
      future: _manifest,
      builder: (context, snapshot) {
        final assets = snapshot.data?.assets;
        return EmojiCover(
            label: '${widget.entry.name}封面',
            image: assets?.isNotEmpty == true
                ? NetworkImage(
                    _assetUrl(widget.catalog, widget.entry, assets!.first))
                : null);
      });
}

class EmojiPackPreviewScreen extends StatefulWidget {
  const EmojiPackPreviewScreen(
      {super.key,
      required this.entry,
      required this.catalog,
      required this.manager,
      this.installedVersion,
      this.installation,
      this.recentManager});
  final EmojiCatalogEntry entry;
  final EmojiPackCatalogRepository catalog;
  final EmojiPackDownloadManager manager;
  final int? installedVersion;
  final EmojiPackInstallation? installation;
  final EmojiRecentManager? recentManager;
  @override
  State<EmojiPackPreviewScreen> createState() => _EmojiPackPreviewScreenState();
}

class _EmojiPackPreviewScreenState extends State<EmojiPackPreviewScreen> {
  late final EmojiRecentManager _recentManager;
  late final String? _account;
  late final EmojiDownloadTask? _initialTask;
  late final bool _initialTaskInstalled;
  EmojiPackManifest? _manifest;
  Object? _error;
  String? _actionError;
  CancelToken? _manifestToken;
  bool _invalidated = false;
  bool _using = false;
  bool get _current =>
      mounted && !_invalidated && _account == _recentManager.userId;

  @override
  void initState() {
    super.initState();
    _recentManager = widget.recentManager ?? EmojiRecentManager.instance;
    _account = _recentManager.userId;
    _initialTask = widget.manager.tasks[widget.entry.id];
    _initialTaskInstalled =
        _initialTask?.status == EmojiDownloadStatus.installed;
    _recentManager.addListener(_sessionChanged);
    unawaited(_loadManifest());
  }

  void _sessionChanged() {
    if (_account == _recentManager.userId) return;
    _invalidated = true;
    _manifestToken?.cancel('账号已切换');
    widget.manager.pause(widget.entry.id);
    if (mounted) setState(() => _manifest = null);
  }

  @override
  void dispose() {
    _manifestToken?.cancel('预览页面已关闭');
    _recentManager.removeListener(_sessionChanged);
    super.dispose();
  }

  Future<void> _loadManifest() async {
    if (!_current) return;
    _manifestToken?.cancel('重新加载预览');
    final token = CancelToken();
    _manifestToken = token;
    setState(() {
      _manifest = null;
      _error = null;
    });
    try {
      final manifest = await widget.catalog.manifest(widget.entry, token);
      if (_current && !token.isCancelled) setState(() => _manifest = manifest);
    } catch (error) {
      if (_current && !token.isCancelled) setState(() => _error = error);
    }
  }

  Future<void> _use() async {
    if (!_current || _using) return;
    setState(() {
      _using = true;
      _actionError = null;
    });
    try {
      final packs = await widget.manager.store.load();
      if (!_current) return;
      final matches = packs.where((pack) =>
          pack.packId == widget.entry.id &&
          pack.version == widget.entry.version &&
          pack.status == EmojiPackInstallStatus.installed);
      if (matches.isEmpty) throw StateError('本机安装尚不可用，请重新下载');
      if (!matches.first.enabled) {
        await widget.manager.store.setEnabled(widget.entry.id, true);
      }
      if (!mounted || !_current) return;
      Navigator.of(context).pop(widget.entry.id);
    } catch (error) {
      if (_current) {
        setState(() => _actionError =
            error is StateError ? error.message.toString() : '启用表情未完成，请重试');
      }
    } finally {
      if (_current) setState(() => _using = false);
    }
  }

  Future<void> _start() async {
    if (!_current) return;
    setState(() => _actionError = null);
    try {
      await widget.manager.start(widget.entry);
    } catch (_) {
      if (_current) setState(() => _actionError = '下载未完成，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => EmojiPageScaffold(
        title: _current ? widget.entry.name : '表情预览',
        body: !_current
            ? const EmojiStateView(title: '账号已切换，请返回')
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  EmojiPackRow(
                      name: widget.entry.name,
                      detail:
                          '${widget.entry.assetCount} 个表情 · ${emojiBytesLabel(widget.entry.totalSize)}',
                      status: '官方表情',
                      cover: EmojiCover(
                          size: 72,
                          image: _manifest?.assets.isNotEmpty == true
                              ? NetworkImage(_assetUrl(widget.catalog,
                                  widget.entry, _manifest!.assets.first))
                              : null)),
                  Text('版本 ${widget.entry.version}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: emojiMuted(context))),
                  const EmojiSectionHeader(title: '表情内容', detail: '点击查看大图'),
                  if (_error != null)
                    EmojiStateView(
                        title: '预览加载失败',
                        detail: '请检查网络后重试。',
                        icon: Icons.cloud_off_outlined,
                        action: OutlinedButton(
                            onPressed: _loadManifest, child: const Text('重试')))
                  else if (_manifest == null)
                    const Padding(
                        padding: EdgeInsets.all(AppSpacing.xxl),
                        child: Center(child: CircularProgressIndicator()))
                  else if (_manifest!.assets.isEmpty)
                    const EmojiStateView(title: '这个表情包还没有内容')
                  else
                    EmojiPreviewGrid(
                        key: ValueKey('emoji-pack-preview-${widget.entry.id}'),
                        shrinkWrap: true,
                        items: [
                          for (final asset in _manifest!.assets)
                            EmojiPreviewItem(
                                id: asset.id,
                                name: asset.name,
                                image: NetworkImage(_assetUrl(
                                    widget.catalog, widget.entry, asset)),
                                animated: asset.animated)
                        ],
                        onSelected: (item) => showEmojiPreview(context, item,
                            session: _recentManager,
                            isCurrent: () => _current)),
                ],
              ),
        bottomNavigationBar: _current
            ? AnimatedBuilder(
                animation: widget.manager,
                builder: (context, _) => _downloadAction(context))
            : null,
      );

  Widget _downloadAction(BuildContext context) {
    final task = widget.manager.tasks[widget.entry.id];
    // 恢复出来的旧 installed 任务不能掩盖损坏；本次新任务完成才解除修复态。
    final completedNow = task?.status == EmojiDownloadStatus.installed &&
        task?.entry.version == widget.entry.version &&
        (!identical(task, _initialTask) || !_initialTaskInstalled);
    final damaged =
        widget.installation?.status == EmojiPackInstallStatus.damaged &&
            !completedNow;
    final installedVersion =
        widget.installation?.version ?? widget.installedVersion;
    final installed =
        !damaged && (installedVersion == widget.entry.version || completedNow);
    final downloading = task?.status == EmojiDownloadStatus.downloading;
    final installing = task?.status == EmojiDownloadStatus.installing;
    final paused = task?.status == EmojiDownloadStatus.paused;
    final label = installed
        ? widget.installation?.enabled == false
            ? '启用并使用'
            : '返回使用'
        : downloading
            ? '暂停下载'
            : installing
                ? '校验并安装中…'
                : paused
                    ? '继续下载并安装'
                    : task?.status == EmojiDownloadStatus.failed
                        ? '重试下载'
                        : damaged
                            ? '重新下载并修复'
                            : installedVersion == null
                                ? '下载并安装'
                                : '更新到 v${widget.entry.version}';
    final disabled = _using ||
        installing ||
        (!installed &&
            (_manifest == null || !widget.manager.flags.officialPackDownload));
    return DecoratedBox(
      decoration: BoxDecoration(
          color: emojiSurface(context),
          border: Border(top: BorderSide(color: emojiBorder(context)))),
      child: SafeArea(
          top: false,
          child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!installed &&
                        !widget.manager.flags.officialPackDownload)
                      const Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Text('官方下载暂未开放，已有表情仍可使用。')),
                    if (downloading || paused || installing) ...[
                      Text(
                          installing
                              ? '下载完成，正在校验并安装'
                              : '${paused ? '已暂停' : '正在下载'} · ${emojiBytesLabel(task!.receivedBytes)} / ${emojiBytesLabel(widget.entry.totalSize)}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: emojiMuted(context))),
                      const SizedBox(height: AppSpacing.sm),
                      LinearProgressIndicator(
                          value: installing || widget.entry.totalSize == 0
                              ? null
                              : (task!.receivedBytes / widget.entry.totalSize)
                                  .clamp(0, 1)),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (_actionError != null || task?.error != null || damaged)
                      Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Text(
                              _actionError ?? task?.error ?? '本机文件损坏，重新下载可以修复。',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                    FilledButton(
                        onPressed: disabled
                            ? null
                            : installed
                                ? _use
                                : downloading
                                    ? () =>
                                        widget.manager.pause(widget.entry.id)
                                    : _start,
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48)),
                        child: _using
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Text(label)),
                  ]))),
    );
  }
}
