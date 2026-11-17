import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/app_dialog.dart';
import 'theme_appearance_exporter.dart';
import 'theme_import_screen.dart';
import 'theme_pack_store.dart';
import 'theme_store_repository.dart';
import 'theme_store_screen.dart';

class InstalledThemesScreen extends StatefulWidget {
  const InstalledThemesScreen({super.key, this.repository});

  final ThemeStoreRepository? repository;

  @override
  State<InstalledThemesScreen> createState() => _InstalledThemesScreenState();
}

class _InstalledThemesScreenState extends State<InstalledThemesScreen> {
  List<InstalledTheme>? _themes;
  Map<String, ThemeCatalogItem> _remoteUpdates = const {};
  String? _error;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  ThemeStoreRepository? _resolveRepo() {
    if (widget.repository != null) return widget.repository;
    final auth = context.read<AuthProvider?>();
    if (auth == null) return null;
    return ThemeStoreRepository(auth.dio);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _error = null);
    try {
      final themes = await context.read<ThemeProvider>().installedThemes();
      if (!mounted || generation != _generation) return;
      setState(() => _themes = themes);
      final repo = _resolveRepo();
      if (repo != null && themes.isNotEmpty) {
        final ids = themes
            .map((t) => (t.familyId ?? t.manifest.id).toLowerCase())
            .toSet()
            .toList();
        try {
          final remoteMap = await repo.checkUpdates(ids);
          if (!mounted || generation != _generation) return;
          final updates = <String, ThemeCatalogItem>{};
          for (final theme in themes) {
            final key = (theme.familyId ?? theme.manifest.id).toLowerCase();
            final remote = remoteMap[key];
            if (remote != null && remote.version > theme.manifest.version) {
              updates[theme.manifest.id] = remote;
            }
          }
          setState(() => _remoteUpdates = updates);
        } catch (_) {
          // 离线或商城未开启时不阻断本机主题管理。
        }
      } else if (mounted && generation == _generation) {
        setState(() => _remoteUpdates = const {});
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '无法读取本机主题，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _openUpdateDetail(ThemeCatalogItem item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ThemeDetailScreen(
          familyId: item.familyId,
          initialItem: item,
          repository: widget.repository,
        ),
      ),
    );
    if (mounted) await _load();
  }

  String _sourceLabel(InstalledTheme theme) {
    return switch (theme.source) {
      'official' => '官方主题',
      'community' => '商城主题',
      _ => '本机主题',
    };
  }

  Future<void> _open([InstalledTheme? theme]) async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
        builder: (_) => ThemeImportScreen(installed: theme)));
    if (mounted) await _load();
  }

  Future<void> _remove(InstalledTheme theme) async {
    final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
              title: Text('删除“${theme.manifest.name}”？'),
              content: const Text('将从本机主题列表移除。当前外观和上一个外观仍可使用，其他资源会清理。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('删除'))
              ],
            ));
    if (!mounted || confirmed != true) return;
    final provider = context.read<ThemeProvider>();
    setState(() => _busy = true);
    try {
      await provider.deleteInstalledTheme(theme.manifest.id);
      if (mounted) await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(InstalledTheme theme, {bool saveToFile = false}) async {
    final store = context.read<ThemeProvider>().themePacks;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final fileName =
        '${ThemeAppearanceExporter.sanitizeFileName(theme.manifest.name, fallback: theme.manifest.id)}.sltheme';
    setState(() => _busy = true);
    try {
      final bytes = await store.export(theme);
      if (!mounted) return;
      if (saveToFile) {
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: '保存主题文件',
          fileName: fileName,
          bytes: bytes,
        );
        if (savedPath != null && savedPath.isNotEmpty) {
          final target = File(savedPath);
          if (!await target.exists() || await target.length() == 0) {
            await target.parent.create(recursive: true);
            await target.writeAsBytes(bytes, flush: true);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已保存 $fileName')),
            );
          }
        }
      } else {
        await Share.shareXFiles([
          XFile.fromData(
            bytes,
            name: fileName,
            mimeType: 'application/vnd.sylulive.theme+zip',
          )
        ], fileNameOverrides: [
          fileName
        ], sharePositionOrigin: origin);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = saveToFile ? '保存失败，请重试。' : '分享失败，请重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('本机主题')),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                      padding: const EdgeInsets.all(18),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        OutlinedButton.icon(
                            onPressed: _busy ? null : () => _open(),
                            icon: const Icon(Icons.file_open_outlined),
                            label: const Text('导入主题')),
                        const SizedBox(height: 12),
                        if (_error != null) ...[
                          Text(_error!, semanticsLabel: _error),
                          TextButton(onPressed: _load, child: const Text('重试'))
                        ],
                        if (_themes == null && _error == null)
                          const Center(child: CircularProgressIndicator()),
                        if (_themes?.isEmpty == true)
                          const Padding(
                              padding: EdgeInsets.symmetric(vertical: 48),
                              child: Column(children: [
                                Icon(Icons.palette_outlined, size: 48),
                                SizedBox(height: 16),
                                Text('还没有本机主题'),
                                SizedBox(height: 8),
                                Text('导入 .sltheme 文件，预览后应用喜欢的部分。',
                                    textAlign: TextAlign.center),
                              ])),
                        for (final theme in _themes ?? <InstalledTheme>[])
                          Builder(builder: (context) {
                            final updateItem =
                                _remoteUpdates[theme.manifest.id];
                            return Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              leading: SizedBox(
                                                  width: 48,
                                                  height: 64,
                                                  child: Image.file(
                                                      File(
                                                          '${theme.directory}/${theme.manifest.data['preview']['light']}'),
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (_, __,
                                                              ___) =>
                                                          const Icon(Icons
                                                              .broken_image_outlined))),
                                              title: Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                        theme.manifest.name),
                                                  ),
                                                  if (updateItem != null) ...[
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 8,
                                                        vertical: 2,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .primaryContainer,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(999),
                                                      ),
                                                      child: Text(
                                                        '可更新 v${updateItem.version}',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Theme.of(
                                                                  context)
                                                              .colorScheme
                                                              .onPrimaryContainer,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              subtitle: Text(
                                                  '${theme.manifest.author} · v${theme.manifest.version}\n${_sourceLabel(theme)}'),
                                              onTap: _busy
                                                  ? null
                                                  : () => _open(theme)),
                                          Wrap(
                                              alignment: WrapAlignment.end,
                                              spacing: 8,
                                              children: [
                                                TextButton(
                                                    onPressed: _busy
                                                        ? null
                                                        : () => _remove(theme),
                                                    child: const Text('删除')),
                                                TextButton(
                                                    onPressed: _busy
                                                        ? null
                                                        : () => _share(theme,
                                                            saveToFile: true),
                                                    child: const Text('保存')),
                                                TextButton(
                                                    onPressed: _busy
                                                        ? null
                                                        : () => _share(theme),
                                                    child: const Text('分享')),
                                                if (updateItem != null)
                                                  OutlinedButton(
                                                      onPressed: _busy
                                                          ? null
                                                          : () =>
                                                              _openUpdateDetail(
                                                                  updateItem),
                                                      child:
                                                          const Text('前往更新')),
                                                FilledButton(
                                                    onPressed: _busy
                                                        ? null
                                                        : () => _open(theme),
                                                    child:
                                                        const Text('预览与应用')),
                                              ]),
                                        ])));
                          }),
                        const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: Text('删除只移出本机主题列表。当前外观和上一个外观使用的资源会保留。')),
                      ]),
                ))),
      );
}
