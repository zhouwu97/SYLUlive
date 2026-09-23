import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../config/api_constants.dart';
import '../../../widgets/campus/campus_theme.dart';
import '../../../widgets/settings/settings_page_scaffold.dart';
import '../../../widgets/emoji/sticker_catalog.dart';
import '../application/emoji_pack_download_manager.dart';
import '../application/emoji_recent_manager.dart';
import '../data/emoji_pack_catalog_repository.dart';
import '../data/emoji_pack_local_store.dart';
import '../domain/emoji_pack_manifest.dart';

class EmojiDownloadScreen extends StatefulWidget {
  const EmojiDownloadScreen({super.key, required this.store, this.repository});
  final EmojiPackLocalStore store;
  final EmojiPackCatalogRepository? repository;
  @override
  State<EmojiDownloadScreen> createState() => _EmojiDownloadScreenState();
}

class _EmojiDownloadScreenState extends State<EmojiDownloadScreen> {
  late final EmojiPackCatalogRepository _catalog;
  late final EmojiPackDownloadManager _manager;
  late final String? _account;
  List<EmojiCatalogEntry>? _entries;
  Map<String, int> _installed = {};
  Object? _error;
  @override
  void initState() {
    super.initState();
    _account = EmojiRecentManager.instance.userId;
    _catalog = widget.repository ??
        EmojiPackCatalogRepository(Dio(BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 30))));
    _manager = EmojiPackDownloadManager.shared(widget.store, _catalog)
      ..addListener(_changed);
    EmojiRecentManager.instance.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    if (_account == EmojiRecentManager.instance.userId) return;
    for (final id in _manager.tasks.keys) {
      _manager.pause(id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await _manager.restore();
      final installed = await widget.store.load();
      final entries = (await _catalog.list())
          .where((entry) => entry.id != appStickerGroups.first.id)
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
        _installed = {for (final item in installed) item.packId: item.version};
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _openPreview(EmojiCatalogEntry entry) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EmojiPackPreviewScreen(
              entry: entry,
              catalog: _catalog,
              manager: _manager,
              installedVersion: _installed[entry.id],
            )));
    if (mounted) await _load();
  }

  @override
  void dispose() {
    EmojiRecentManager.instance.removeListener(_sessionChanged);
    _manager.removeListener(_changed);
    for (final id in _manager.tasks.keys) {
      _manager.pause(id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SettingsPageScaffold(title: '服务器表情包', children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 12),
          child: Text('先预览表情内容，再下载到本机。安装后会出现在输入面板底部。'),
        ),
        if (_error != null)
          ListTile(
              title: const Text('服务器目录暂不可用'),
              trailing: TextButton(onPressed: _load, child: const Text('重试')))
        else if (_entries == null)
          const Center(child: CircularProgressIndicator())
        else if (_entries!.isEmpty)
          const ListTile(title: Text('暂无可下载的服务器表情包'))
        else
          for (final entry in _entries!) _tile(entry),
      ]);
  Widget _tile(EmojiCatalogEntry entry) {
    final task = _manager.tasks[entry.id];
    final downloading = task?.status == EmojiDownloadStatus.downloading;
    final installing = task?.status == EmojiDownloadStatus.installing;
    final installed = _installed[entry.id] == entry.version ||
        (task?.status == EmojiDownloadStatus.installed &&
            task?.entry.version == entry.version);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
          title: Text(entry.name),
          subtitle: Text('${entry.assetCount} 个表情 · '
              '${(entry.totalSize / 1024 / 1024).toStringAsFixed(1)} MB · v${entry.version}'
              '${installed ? ' · 已安装' : ''}'),
          leading: Icon(installed
              ? Icons.check_circle_outline_rounded
              : Icons.collections_outlined),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => unawaited(_openPreview(entry))),
      if (downloading)
        LinearProgressIndicator(
            value: entry.totalSize == 0
                ? null
                : (task!.receivedBytes / entry.totalSize).clamp(0, 1)),
      if (installing) const LinearProgressIndicator(),
      if (task?.error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(task!.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      const Divider(),
    ]);
  }
}

class EmojiPackPreviewScreen extends StatefulWidget {
  const EmojiPackPreviewScreen({
    super.key,
    required this.entry,
    required this.catalog,
    required this.manager,
    this.installedVersion,
  });

  final EmojiCatalogEntry entry;
  final EmojiPackCatalogRepository catalog;
  final EmojiPackDownloadManager manager;
  final int? installedVersion;

  @override
  State<EmojiPackPreviewScreen> createState() => _EmojiPackPreviewScreenState();
}

class _EmojiPackPreviewScreenState extends State<EmojiPackPreviewScreen> {
  EmojiPackManifest? _manifest;
  Object? _error;
  CancelToken? _manifestToken;

  @override
  void initState() {
    super.initState();
    _loadManifest();
  }

  @override
  void dispose() {
    _manifestToken?.cancel('预览页面已关闭');
    super.dispose();
  }

  Future<void> _loadManifest() async {
    _manifestToken?.cancel('重新加载预览');
    final token = CancelToken();
    _manifestToken = token;
    setState(() {
      _manifest = null;
      _error = null;
    });
    try {
      final manifest = await widget.catalog.manifest(widget.entry, token);
      if (!mounted || token.isCancelled) return;
      setState(() => _manifest = manifest);
    } catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() => _error = error);
    }
  }

  String _assetUrl(EmojiManifestAsset asset) {
    final baseUrl = ApiConstants.baseUrl.endsWith('/')
        ? ApiConstants.baseUrl
        : '${ApiConstants.baseUrl}/';
    final path = Uri.parse(baseUrl).resolve(
        'emoji/packs/${widget.entry.id}/assets/${Uri.encodeComponent(asset.id)}');
    return path.replace(
        queryParameters: {'version': '${widget.entry.version}'}).toString();
  }

  @override
  Widget build(BuildContext context) {
    final pageBackground = CampusTheme.pageBackground(context);
    return Theme(
      data: CampusTheme.withBrandAccent(Theme.of(context)),
      child: Scaffold(
        backgroundColor: pageBackground,
        appBar: AppBar(
          title: Text(widget.entry.name),
          backgroundColor: pageBackground,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          elevation: 0,
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Row(
                children: [
                  const Icon(Icons.cloud_download_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${widget.entry.assetCount} 个表情 · '
                      '${(widget.entry.totalSize / 1024 / 1024).toStringAsFixed(1)} MB · '
                      'v${widget.entry.version}\n下载前可逐个预览，安装后即可在面板中使用。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildPreviewGrid(context)),
          ],
        ),
        bottomNavigationBar: AnimatedBuilder(
          animation: widget.manager,
          builder: (context, _) => _buildDownloadAction(context),
        ),
      ),
    );
  }

  Widget _buildPreviewGrid(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('预览加载失败，请检查网络后重试。'),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadManifest, child: const Text('重试')),
          ],
        ),
      );
    }
    final manifest = _manifest;
    if (manifest == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (manifest.assets.isEmpty) return const Center(child: Text('这个表情包还没有内容'));
    return GridView.builder(
      key: ValueKey('emoji-pack-preview-${widget.entry.id}'),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisExtent: 124,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: manifest.assets.length,
      itemBuilder: (context, index) {
        final asset = manifest.assets[index];
        return Semantics(
          image: true,
          label: asset.name,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Expanded(
                    child: Image.network(
                      _assetUrl(asset),
                      fit: BoxFit.contain,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    asset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDownloadAction(BuildContext context) {
    final task = widget.manager.tasks[widget.entry.id];
    final isInstalled = widget.installedVersion == widget.entry.version ||
        (task?.status == EmojiDownloadStatus.installed &&
            task?.entry.version == widget.entry.version);
    final isDownloading = task?.status == EmojiDownloadStatus.downloading;
    final isInstalling = task?.status == EmojiDownloadStatus.installing;
    final busy = _manifest == null;
    final label = isInstalled
        ? '已安装，可返回使用'
        : isDownloading
            ? '暂停下载'
            : isInstalling
                ? '安装中，请稍候'
                : task?.status == EmojiDownloadStatus.paused
                    ? '继续下载并安装'
                    : task?.status == EmojiDownloadStatus.failed
                        ? '重试下载'
                        : widget.installedVersion == null
                            ? '下载并安装'
                            : '更新到 v${widget.entry.version}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
            top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isDownloading)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(
                    value: widget.entry.totalSize == 0
                        ? null
                        : (task!.receivedBytes / widget.entry.totalSize)
                            .clamp(0, 1),
                  ),
                ),
              if (task?.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(task!.error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              FilledButton(
                onPressed: busy || isInstalled || isInstalling
                    ? null
                    : isDownloading
                        ? () => widget.manager.pause(widget.entry.id)
                        : () => unawaited(widget.manager.start(widget.entry)),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
