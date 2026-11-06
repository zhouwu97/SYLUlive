import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/security_session_guard.dart';
import '../data/emoji_pack_local_store.dart';
import '../domain/emoji_creation_draft.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import 'emoji_local_thumbnail.dart';
import 'emoji_session_state.dart';
import 'emoji_ui.dart';

class EmojiCreationEditorScreen extends StatefulWidget {
  const EmojiCreationEditorScreen(
      {super.key, required this.store, this.revisionOf});
  final EmojiPackLocalStore store;
  final String? revisionOf;
  @override
  State<EmojiCreationEditorScreen> createState() => _EmojiCreationEditorState();
}

class _EmojiCreationEditorState
    extends EmojiSessionState<EmojiCreationEditorScreen> {
  List<EmojiPackInstallation>? _packs;
  EmojiPackInstallation? _selected;
  EmojiCreationDraft? _draft;
  final _name = TextEditingController(),
      _description = TextEditingController(),
      _tags = TextEditingController();
  final _labels = <String, TextEditingController>{};
  Timer? _saveTimer;
  bool _allowed = false,
      _busy = false,
      _selecting = false,
      _rights = false,
      _saved = true;
  bool _allowExit = false, _leaving = false;
  String? _error, _saveError;
  double? _progress;
  int _selectionGeneration = 0;

  bool get _valid =>
      _draft != null &&
      _name.text.trim().isNotEmpty &&
      _name.text.characters.length <= 40 &&
      _labels.values.every((label) =>
          label.text.trim().isNotEmpty && label.text.characters.length <= 40) &&
      _tags.text
              .split(RegExp('[,，]'))
              .where((tag) => tag.trim().isNotEmpty)
              .length <=
          5 &&
      _tags.text
          .split(RegExp('[,，]'))
          .every((tag) => tag.trim().characters.length <= 12);

  @override
  void initState() {
    super.initState();
    if (current) unawaited(_load());
  }

  Future<void> _load() async {
    if (!current) return;
    final request = nextRequest();
    setState(() {
      _error = null;
      _allowed = false;
      _packs = null;
    });
    try {
      final creator =
          await repository!.creator(session: session!, token: request);
      if (!current || request.isCancelled) return;
      if (!creator.active) {
        setState(() => _error = '请先从创作中心申请并开通权限。本机导入自用不受影响。');
        return;
      }
      final packs = await widget.store.load();
      if (!current || request.isCancelled) return;
      setState(() {
        _allowed = true;
        _packs = packs
            .where((pack) =>
                pack.trustLevel == EmojiPackTrustLevel.localUntrusted &&
                !pack.isCatalogPack &&
                pack.status == EmojiPackInstallStatus.installed)
            .toList();
      });
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
      }
    }
  }

  Future<void> _select(EmojiPackInstallation pack) async {
    if (!current || _busy || _selecting) return;
    final generation = ++_selectionGeneration;
    _saveTimer?.cancel();
    setState(() => _selecting = true);
    try {
      await _persist();
      final fresh =
          EmojiCreationDraft.fromPack(pack, revisionOf: widget.revisionOf);
      final saved = await widget.store.loadDraft(fresh.key);
      if (!current || generation != _selectionGeneration) return;
      final draft = saved != null &&
              saved.sourceVersion == pack.version &&
              saved.sourceManifestHash == pack.manifestSha256
          ? saved
          : fresh;
      for (final controller in _labels.values) {
        controller.dispose();
      }
      _labels.clear();
      for (final asset in pack.manifest.assets) {
        _labels[asset.id] =
            TextEditingController(text: draft.names[asset.id] ?? asset.name);
      }
      setState(() {
        _selected = pack;
        _draft = draft;
        _name.text = draft.name;
        _description.text = draft.description;
        _tags.text = draft.tags.join('，');
        _rights = false;
        _error = null;
        _saved = saved != null;
      });
      if (saved == null) await _persist();
    } catch (_) {
      if (current) setState(() => _saveError = '读取或保存草稿失败，请重试。');
    } finally {
      if (current && generation == _selectionGeneration) {
        setState(() => _selecting = false);
      }
    }
  }

  void _capture() {
    final draft = _draft;
    if (draft == null) return;
    draft.name = _name.text.trim();
    draft.description = _description.text.trim();
    draft.tags = _tags.text
        .split(RegExp('[,，]'))
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    draft.names = {
      for (final entry in _labels.entries) entry.key: entry.value.text.trim()
    };
  }

  void _changed() {
    if (!current) return;
    _capture();
    setState(() => _saved = false);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400),
        () => unawaited(_persist().catchError((_) {})));
  }

  Future<void> _persist() async {
    final draft = _draft;
    if (draft == null) return;
    _capture();
    final snapshot = jsonEncode(draft.toJson());
    try {
      await widget.store.saveDraft(draft);
      if (current &&
          identical(draft, _draft) &&
          snapshot == jsonEncode(draft.toJson())) {
        setState(() {
          _saved = true;
          _saveError = null;
        });
      }
    } catch (_) {
      if (current) setState(() => _saveError = '草稿尚未保存，请重试后离开。');
      rethrow;
    }
  }

  @override
  void onSessionInvalidated() {
    _selectionGeneration++;
    _saveTimer?.cancel();
    if (_draft != null && !_saved) {
      _capture();
      unawaited(widget.store.saveDraft(_draft!).catchError((_) {}));
    }
  }

  Future<void> _preview() async {
    if (!current || !_valid) return;
    _capture();
    final pack = _selected!, draft = _draft!;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SecuritySessionGuard(
            auth: auth!,
            session: session!,
            child: _EmojiCreationPreview(
                store: widget.store,
                pack: pack,
                draft: EmojiCreationDraft.fromJson(draft.toJson()),
                isCurrent: () => current,
                session: auth!))));
  }

  Future<void> _submit() async {
    if (!current || !_allowed || _busy || !_rights || !_valid) return;
    final request = nextRequest();
    _saveTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    try {
      await _persist();
      final creator =
          await repository!.creator(session: session!, token: request);
      if (!current || request.isCancelled) return;
      if (!creator.active) {
        setState(() => _allowed = false);
        throw StateError('创作者权限已变化，草稿保留，请返回创作中心查看。');
      }
      _capture();
      await repository!.submit(
          pack: _selected!,
          store: widget.store,
          name: _name.text,
          description: _description.text,
          draft: _draft,
          session: session!,
          token: request,
          onProgress: (sent, total) {
            if (current && !request.isCancelled) {
              setState(() => _progress = total > 0 ? sent / total : null);
            }
          });
      await widget.store.removeDraft(_draft!.key);
      if (!mounted || !current || request.isCancelled) return;
      _draft = null;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已提交审核，结果可在我的作品查看')));
      Navigator.of(context).pop();
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() {
          _error = failureMessage(error);
          if (error is DioException &&
              error.response?.data is Map &&
              error.response?.data['code'] == 'emoji_creator_required') {
            _allowed = false;
          }
        });
      }
    } finally {
      if (current && identical(request, token)) setState(() => _busy = false);
    }
  }

  Future<bool> _leave() async {
    if (_busy) return false;
    _saveTimer?.cancel();
    try {
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_draft != null && !_saved) {
      _capture();
      unawaited(widget.store.saveDraft(_draft!).catchError((_) {}));
    }
    _name.dispose();
    _description.dispose();
    _tags.dispose();
    for (final controller in _labels.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: _allowExit || !_busy && (_draft == null || _saved),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _leaving) return;
        _leaving = true;
        if (await _leave() && mounted) {
          setState(() => _allowExit = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop(result);
          });
        }
        _leaving = false;
      },
      child: EmojiPageScaffold(
          title: widget.revisionOf == null ? '制作表情包' : '制作新版本',
          formLayout: true,
          body: !current
              ? permissionState
              : ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                      const EmojiSectionHeader(
                          title: '从本机包开始制作',
                          detail:
                              '自用包与公开作品独立；每次最多 100 张、合计 49 MB，单张不超过 10 MB。'),
                      if (widget.revisionOf != null)
                        const Text('新版本通过审核前，商城继续提供原来的已通过版本。'),
                      if (_packs == null && _error == null)
                        const LinearProgressIndicator(),
                      if (_packs?.isEmpty == true)
                        const EmojiStateView(
                            title: '还没有可制作的本机包',
                            detail: '返回表情管理，从相册或文件导入素材后再来制作。'),
                      for (final pack in _packs ?? <EmojiPackInstallation>[])
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            enabled: _allowed && !_busy && !_selecting,
                            leading: EmojiCover(
                                image: pack.manifest.assets.isEmpty
                                    ? null
                                    : _thumbnail(
                                        pack, pack.manifest.assets.first.id)),
                            title: Text(pack.name),
                            subtitle: Text(
                                '${pack.manifest.assets.length} 个 · ${emojiBytesLabel(pack.totalSize)}'),
                            trailing: Icon(_selected?.packId == pack.packId
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off),
                            selected: _selected?.packId == pack.packId,
                            onTap: () => unawaited(_select(pack))),
                      if (_selecting) const LinearProgressIndicator(),
                      if (_draft != null) ...[
                        Text(
                            _saveError != null
                                ? '本机草稿尚未保存'
                                : _saved
                                    ? '本机草稿已保存 · 尚未公开'
                                    : '正在保存本机草稿…',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: AppSpacing.md),
                        TextField(
                            controller: _name,
                            enabled: !_busy,
                            maxLength: 40,
                            onChanged: (_) => _changed(),
                            decoration: const InputDecoration(
                                labelText: '公开名称',
                                border: OutlineInputBorder())),
                        const SizedBox(height: AppSpacing.md),
                        TextField(
                            controller: _description,
                            enabled: !_busy,
                            maxLength: 300,
                            minLines: 2,
                            maxLines: 4,
                            onChanged: (_) => _changed(),
                            decoration: const InputDecoration(
                                labelText: '简介（选填）',
                                border: OutlineInputBorder())),
                        const EmojiSectionHeader(
                            title: '图片与对应文字',
                            detail: '缩略图自动生成；文字用于搜索和朗读，发送时只发送图片。'),
                        for (final asset in _selected!.manifest.assets)
                          Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: AppSpacing.sm),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          EmojiCover(
                                              size: 64,
                                              image: _thumbnail(
                                                  _selected!, asset.id)),
                                          const SizedBox(width: AppSpacing.md),
                                          Expanded(
                                              child: TextField(
                                                  key: ValueKey(
                                                      'emoji-label-${asset.id}'),
                                                  controller: _labels[asset.id],
                                                  enabled: !_busy,
                                                  maxLength: 40,
                                                  onChanged: (_) => _changed(),
                                                  decoration: const InputDecoration(
                                                      labelText: '对应文字',
                                                      border:
                                                          OutlineInputBorder())))
                                        ]),
                                    Wrap(spacing: AppSpacing.sm, children: [
                                      TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () {
                                                  _draft!.coverAssetId =
                                                      asset.id;
                                                  _changed();
                                                },
                                          child: Text(
                                              _draft!.coverAssetId == asset.id
                                                  ? '✓ 当前封面'
                                                  : '设为封面')),
                                      TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () {
                                                  _draft!.iconAssetId =
                                                      asset.id;
                                                  _changed();
                                                },
                                          child: Text(
                                              _draft!.iconAssetId == asset.id
                                                  ? '✓ 面板图标'
                                                  : '设为面板图标')),
                                    ]),
                                  ])),
                        TextField(
                            controller: _tags,
                            enabled: !_busy,
                            onChanged: (_) => _changed(),
                            maxLength: 64,
                            decoration: const InputDecoration(
                                labelText: '公开标签（选填）',
                                helperText: '用逗号分隔，最多 5 个，每个最多 12 个字符',
                                border: OutlineInputBorder())),
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _rights,
                            onChanged: _busy
                                ? null
                                : (value) =>
                                    setState(() => _rights = value == true),
                            title: const Text('我有权公开分享全部图片、封面和文字'),
                            subtitle: const Text('作品审核通过后，免费提供给所有用户下载使用。')),
                      ],
                      if (_saveError != null)
                        EmojiInlineError(
                            message: _saveError!,
                            onRetry: _busy
                                ? null
                                : () =>
                                    unawaited(_persist().catchError((_) {}))),
                      if (_error != null)
                        EmojiInlineError(
                            message: _error!,
                            onRetry: _busy
                                ? null
                                : _packs == null
                                    ? _load
                                    : _allowed
                                        ? _submit
                                        : null),
                      if (_busy)
                        Semantics(
                            liveRegion: true,
                            child: Column(children: [
                              LinearProgressIndicator(value: _progress),
                              const SizedBox(height: AppSpacing.sm),
                              Text(_progress == 1
                                  ? '图片已传输，正在提交审核…'
                                  : '正在上传，请稍候…'),
                              TextButton(
                                  onPressed: () {
                                    token.cancel('用户取消上传');
                                    setState(() {
                                      _busy = false;
                                      _progress = null;
                                      _error = '上传已取消，草稿保留。已提交的内容可在“我的作品”查看。';
                                    });
                                  },
                                  child: const Text('取消上传，保留草稿')),
                            ])),
                    ]),
          bottomNavigationBar: !current || _draft == null
              ? null
              : SafeArea(
                  top: false,
                  child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton(
                                onPressed: _busy || !_valid ? null : _preview,
                                child: const Text('预览上架效果')),
                            const SizedBox(height: AppSpacing.sm),
                            FilledButton(
                                onPressed:
                                    _busy || !_allowed || !_rights || !_valid
                                        ? null
                                        : _submit,
                                style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48)),
                                child: Text(_busy ? '提交中…' : '提交审核')),
                          ])))));
  ImageProvider _thumbnail(EmojiPackInstallation pack, String id) {
    final asset = pack.manifest.assets.firstWhere((asset) => asset.id == id);
    return emojiInstalledThumbnail(widget.store, pack, asset);
  }
}

class _EmojiCreationPreview extends StatelessWidget {
  const _EmojiCreationPreview(
      {required this.store,
      required this.pack,
      required this.draft,
      required this.isCurrent,
      required this.session});
  final EmojiPackLocalStore store;
  final EmojiPackInstallation pack;
  final EmojiCreationDraft draft;
  final bool Function() isCurrent;
  final Listenable session;
  ImageProvider _thumbnail(String id) {
    final asset =
        pack.manifest.assets.where((asset) => asset.id == id).firstOrNull ??
            pack.manifest.assets.first;
    return emojiInstalledThumbnail(store, pack, asset);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) => EmojiPageScaffold(
          title: '上架效果预览',
          body: !isCurrent()
              ? const EmojiStateView(title: '账号已切换，请返回')
              : ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                      EmojiPackRow(
                          name: draft.name,
                          detail:
                              '${pack.manifest.assets.length} 个表情 · 创作者作品 · 免费',
                          cover: EmojiCover(
                              size: 72, image: _thumbnail(draft.coverAssetId))),
                      Row(children: [
                        const Text('输入面板图标：'),
                        EmojiCover(
                            size: 40, image: _thumbnail(draft.iconAssetId))
                      ]),
                      const Text('本机草稿 · 尚未上架 · 审核通过后免费下载'),
                      if (draft.description.isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.md),
                            child: Text(draft.description)),
                      if (draft.tags.isNotEmpty) Text(draft.tags.join(' · ')),
                      const EmojiSectionHeader(
                          title: '全部表情', detail: '点击查看发送图片'),
                      EmojiPreviewGrid(
                          shrinkWrap: true,
                          items: [
                            for (final asset in pack.manifest.assets)
                              EmojiPreviewItem(
                                  id: asset.id,
                                  name: draft.names[asset.id] ?? asset.name,
                                  image: emojiInstalledThumbnail(store, pack, asset),
                                  previewImage: FileImage(File(
                                      '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}')),
                                  animated: asset.animated)
                          ],
                          onSelected: (item) => showEmojiPreview(context, item,
                              session: session, isCurrent: isCurrent)),
                      const Text('对应文字用于搜索和无障碍朗读，发送时只发送图片。'),
                    ])));
}
