import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../theme/app_spacing.dart';
import '../application/emoji_pack_importer.dart';
import '../application/emoji_pack_installer.dart';
import '../application/emoji_recent_manager.dart';
import '../data/emoji_pack_local_store.dart';
import 'emoji_ui.dart';

enum EmojiImportSource { images, archive }

class EmojiImportScreen extends StatefulWidget {
  const EmojiImportScreen(
      {super.key,
      required this.store,
      this.recentManager,
      this.initialSource,
      this.pickImages,
      this.pickArchive});
  final EmojiPackLocalStore store;
  final EmojiRecentManager? recentManager;
  final EmojiImportSource? initialSource;
  final Future<List<File>?> Function()? pickImages;
  final Future<File?> Function()? pickArchive;
  @override
  State<EmojiImportScreen> createState() => _EmojiImportScreenState();
}

class _EmojiImportScreenState extends State<EmojiImportScreen> {
  late final EmojiPackImporter _importer;
  late final EmojiRecentManager _session;
  late final String? _account;
  final _name = TextEditingController();
  PreparedEmojiPack? _prepared;
  String? _error;
  EmojiImportSource? _lastSource;
  bool _busy = false, _installing = false, _invalid = false;
  bool _installError = false;
  bool get _current => mounted && !_invalid && _account == _session.userId;

  @override
  void initState() {
    super.initState();
    _session = widget.recentManager ?? EmojiRecentManager.instance;
    _account = _session.userId;
    _importer = EmojiPackImporter(EmojiPackInstaller(widget.store));
    _session.addListener(_sessionChanged);
    if (widget.initialSource != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current) unawaited(_pick(widget.initialSource!));
      });
    }
  }

  void _sessionChanged() {
    if (_account == _session.userId) return;
    _invalid = true;
    if (mounted) {
      setState(() {
        _prepared = null;
        _name.clear();
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_sessionChanged);
    _name.dispose();
    super.dispose();
  }

  Future<List<File>?> _images() async {
    final images = await ImagePicker().pickMultiImage();
    return images.isEmpty
        ? null
        : images.map((file) => File(file.path)).toList();
  }

  Future<File?> _archive() async {
    // 系统 MIME 表通常不认识 sylupack；由导入器核验扩展名和内容，避免系统先隐藏文件。
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final filePath = result?.files.single.path;
    return filePath == null ? null : File(filePath);
  }

  Future<void> _pick(EmojiImportSource source) async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _lastSource = source;
      _installError = false;
    });
    try {
      PreparedEmojiPack? prepared;
      if (source == EmojiImportSource.images) {
        final files = await (widget.pickImages ?? _images)();
        if (!_current || files == null || files.isEmpty) return;
        prepared = await _importer.prepareImages(files);
      } else {
        final file = await (widget.pickArchive ?? _archive)();
        if (!_current || file == null) return;
        prepared = await _importer.prepareFile(file);
      }
      if (!_current) return;
      setState(() {
        _prepared = prepared;
        _name.text = prepared!.name.characters.take(40).toString();
      });
    } catch (error) {
      if (_current) {
        setState(() => _error = switch (error) {
              FormatException() => error.message,
              PlatformException() => '无法打开相册或文件，请检查系统权限后重试。',
              _ => '读取表情失败，请重新选择文件。',
            });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final prepared = _prepared;
    if (!_current || _busy || prepared == null || _name.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _installing = true;
      _installError = true;
      _error = null;
    });
    try {
      final pack = await _importer.installPrepared(prepared,
          name: _name.text.trim(), isCurrent: () => _current);
      if (!mounted || !_current) return;
      Navigator.of(context).pop(pack.packId);
    } catch (error) {
      if (_current) {
        setState(() => _error =
            error is FormatException ? error.message : '安装未完成，请重试。已有表情包会保留。');
      }
    } finally {
      if (_current) {
        setState(() {
          _busy = false;
          _installing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final prepared = _prepared;
    return EmojiPageScaffold(
      title: '导入表情包',
      formLayout: true,
      body: !_current
          ? const EmojiStateView(title: '账号已切换，请返回重新导入')
          : ListView(padding: const EdgeInsets.all(AppSpacing.lg), children: [
              const EmojiSectionHeader(
                  title: '把喜欢的图片变成表情', detail: '可多选相册图片，或直接导入图片 ZIP，无需手动制作清单。'),
              OutlinedButton.icon(
                  onPressed:
                      _busy ? null : () => _pick(EmojiImportSource.images),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('从相册选择')),
              OutlinedButton.icon(
                  onPressed:
                      _busy ? null : () => _pick(EmojiImportSource.archive),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('选择 ZIP / sylupack 文件')),
              Text('支持 PNG、JPG、GIF；最多 500 张，单张 15 MB，ZIP 最多 100 MB。',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: emojiMuted(context))),
              if (_busy)
                Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                    child: Semantics(
                        liveRegion: true,
                        child: Column(children: [
                          const LinearProgressIndicator(),
                          const SizedBox(height: AppSpacing.sm),
                          Text(_installing ? '正在安装表情包…' : '正在读取并校验图片…'),
                        ]))),
              if (_error != null)
                EmojiInlineError(
                    message: _error!,
                    onRetry: _busy || _installError && _name.text.trim().isEmpty
                        ? null
                        : _installError
                            ? _install
                            : () =>
                                _pick(_lastSource ?? EmojiImportSource.images)),
              if (prepared != null) ...[
                const SizedBox(height: AppSpacing.lg),
                TextField(
                    controller: _name,
                    enabled: !_busy,
                    maxLength: 40,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: '表情包名称', border: OutlineInputBorder())),
                EmojiSectionHeader(
                    title: '导入预览',
                    detail:
                        '${prepared.manifest.assets.length} 个表情 · ${emojiBytesLabel(prepared.manifest.totalSize)} · 已去重'),
                EmojiPreviewGrid(
                    shrinkWrap: true,
                    items: [
                      for (final asset in prepared.manifest.assets)
                        EmojiPreviewItem(
                            id: asset.id,
                            name: asset.name,
                            image: MemoryImage(
                                prepared.thumbnails[asset.path] ??
                                    prepared.contents[asset.path]!),
                            previewImage:
                                MemoryImage(prepared.contents[asset.path]!),
                            animated: asset.animated),
                    ],
                    onSelected: (item) => showEmojiPreview(context, item,
                        session: _session, isCurrent: () => _current)),
                const SizedBox(height: AppSpacing.md),
                const Text('导入后仅保存在本机。想分享给大家，可到“我的投稿”提交审核。'),
              ],
            ]),
      bottomNavigationBar: !_current || prepared == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: FilledButton(
                      onPressed:
                          _busy || _name.text.trim().isEmpty ? null : _install,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      child: Text(_installing ? '正在安装…' : '确认导入并使用')))),
    );
  }
}
