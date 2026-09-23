import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../config/api_constants.dart';
import '../../../widgets/settings/settings_page_scaffold.dart';
import '../application/emoji_pack_download_manager.dart';
import '../application/emoji_recent_manager.dart';
import '../data/emoji_pack_catalog_repository.dart';
import '../data/emoji_pack_local_store.dart';

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
      final entries = await _catalog.list();
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

  Future<void> _start(EmojiCatalogEntry entry) async {
    try {
      await _manager.start(entry);
    } catch (_) {
      if (mounted) setState(() => _error = '任务保存失败');
    }
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
      SettingsPageScaffold(title: '官方表情包', children: [
        if (_error != null)
          ListTile(
              title: const Text('官方目录暂不可用'),
              trailing: TextButton(onPressed: _load, child: const Text('重试')))
        else if (_entries == null)
          const Center(child: CircularProgressIndicator())
        else if (_entries!.isEmpty)
          const ListTile(title: Text('暂无可下载的官方表情包'))
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
              '${(entry.totalSize / 1024 / 1024).toStringAsFixed(1)} MB · v${entry.version}')),
      if (downloading)
        LinearProgressIndicator(
            value: entry.totalSize == 0
                ? null
                : (task!.receivedBytes / entry.totalSize).clamp(0, 1)),
      if (installing) const LinearProgressIndicator(),
      if (task?.error != null)
        Text(task!.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      Align(
          alignment: Alignment.centerRight,
          child: TextButton(
              onPressed: installing
                  ? null
                  : downloading
                      ? () => _manager.pause(entry.id)
                      : () => unawaited(_start(entry)),
              child: Text(
                installing
                    ? '安装中，请稍候'
                    : downloading
                        ? '暂停'
                        : installed
                            ? '已安装 · 重新校验'
                            : task?.status == EmojiDownloadStatus.paused
                                ? '继续下载'
                                : task?.status == EmojiDownloadStatus.failed
                                    ? '重试'
                                    : _installed.containsKey(entry.id)
                                        ? '更新'
                                        : '下载',
              ))),
      const Divider(),
    ]);
  }
}
