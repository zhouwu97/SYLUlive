import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_popup_menu.dart';
import 'package:shenliyuan/widgets/app_dialog.dart';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../../config/api_constants.dart';
import '../../../services/emoji_favorite_service.dart';
import '../../../theme/app_radius.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/emoji/sticker_catalog.dart';
import '../application/emoji_pack_installer.dart';
import '../application/emoji_recent_manager.dart';
import '../data/emoji_pack_local_store.dart';
import '../data/emoji_pack_runtime.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import 'emoji_download_screen.dart';
import 'emoji_ui.dart';

enum _PackAction { preview, up, down, rollback, remove }

class EmojiManagementScreen extends StatefulWidget {
  const EmojiManagementScreen(
      {super.key,
      this.store,
      this.favoriteService,
      this.recentManager,
      this.onAddImage,
      this.favoriteHeaders,
      this.returnToPicker = false});
  final EmojiPackLocalStore? store;
  final EmojiFavoriteService? favoriteService;
  final EmojiRecentManager? recentManager;
  final VoidCallback? onAddImage;
  final Map<String, String> Function()? favoriteHeaders;
  final bool returnToPicker;

  @override
  State<EmojiManagementScreen> createState() => _EmojiManagementScreenState();
}

class _EmojiManagementScreenState extends State<EmojiManagementScreen> {
  late final EmojiFavoriteService _favoriteService;
  late final EmojiRecentManager _recentManager;
  EmojiPackLocalStore? _store;
  List<EmojiPackInstallation>? _packs;
  List<EmojiFavoriteItem>? _favorites;
  Object? _error;
  String? _favoriteError;
  String? _accountId;
  String? _busyPackId;
  bool _busy = false;
  bool _sorting = false;
  bool _selecting = false;
  bool _showFavorites = false;
  bool _menuOpen = false;
  int _storageBytes = 0;
  int _generation = 0;
  int _favoriteGeneration = 0;
  int _accountEpoch = 0;
  String _query = '';
  final Set<String> _selected = {};

  bool _current(int epoch) => mounted && epoch == _accountEpoch;

  @override
  void initState() {
    super.initState();
    _favoriteService = widget.favoriteService ?? EmojiFavoriteService.instance;
    _recentManager = widget.recentManager ?? EmojiRecentManager.instance;
    _accountId = _recentManager.userId;
    _recentManager.addListener(_accountChanged);
    _favoriteService.addListener(_favoritesChanged);
    unawaited(_load());
    unawaited(_loadFavorites());
  }

  void _accountChanged() {
    if (_accountId == _recentManager.userId) return;
    _accountEpoch++;
    _generation++;
    _favoriteGeneration++;
    if (_menuOpen) {
      _menuOpen = false;
      Navigator.of(context).pop();
    }
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    setState(() {
      _accountId = _recentManager.userId;
      _store = null;
      _packs = null;
      _favorites = null;
      _error = null;
      _favoriteError = null;
      _busy = false;
      _busyPackId = null;
      _sorting = false;
      _selecting = false;
      _selected.clear();
      _query = '';
    });
    unawaited(_load());
    unawaited(_loadFavorites());
  }

  void _favoritesChanged() => unawaited(_loadFavorites());

  @override
  void dispose() {
    _recentManager.removeListener(_accountChanged);
    _favoriteService.removeListener(_favoritesChanged);
    super.dispose();
  }

  Future<void> _loadFavorites({bool sync = false}) async {
    final generation = ++_favoriteGeneration;
    final epoch = _accountEpoch;
    final favoriteAccount = _favoriteService.userId;
    try {
      if (sync) await _favoriteService.syncFromServer();
      final items = await _favoriteService.load();
      if (!_current(epoch) ||
          generation != _favoriteGeneration ||
          favoriteAccount != _favoriteService.userId) {
        return;
      }
      setState(() {
        _favorites = items;
        _favoriteError = _favoriteService.syncErrorMessage;
        _selected.removeWhere((key) => !items.any((item) => item.key == key));
      });
    } catch (_) {
      if (_current(epoch) && generation == _favoriteGeneration) {
        setState(() => _favoriteError = '读取收藏失败，请重试');
      }
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final epoch = _accountEpoch;
    try {
      final store =
          widget.store ?? await EmojiPackRuntime.forAccount(_accountId);
      final packs = await store.load();
      final storageBytes = widget.store == null
          ? await store.storageBytes()
          : packs.fold<int>(0, (sum, pack) => sum + pack.totalSize);
      final audited = <EmojiPackInstallation>[];
      for (final pack in packs) {
        if (!_current(epoch) || generation != _generation) return;
        var damaged = false;
        for (final asset in pack.manifest.assets) {
          final file = File(
              '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}');
          if (!await file.exists() ||
              await file.length() != asset.fileSize ||
              (await sha256.bind(file.openRead()).first).toString() !=
                  asset.sha256.toLowerCase()) {
            damaged = true;
            break;
          }
        }
        if (!_current(epoch) || generation != _generation) return;
        if (damaged && pack.status != EmojiPackInstallStatus.damaged) {
          await store.exclusive(() => store
              .commit(pack.copyWith(status: EmojiPackInstallStatus.damaged)));
        }
        audited.add(damaged
            ? pack.copyWith(status: EmojiPackInstallStatus.damaged)
            : pack);
      }
      if (!_current(epoch) || generation != _generation) return;
      setState(() {
        _store = store;
        _packs = audited;
        _storageBytes = storageBytes;
        _error = null;
      });
    } catch (error) {
      if (_current(epoch) && generation == _generation) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_load(), _loadFavorites(sync: true)]);
  }

  Future<void> _run(Future<void> Function() action, {String? packId}) async {
    if (_busy) return;
    final epoch = _accountEpoch;
    setState(() {
      _busy = true;
      _busyPackId = packId;
    });
    try {
      await action();
      if (_current(epoch)) await _load();
    } catch (error) {
      if (_current(epoch)) {
        _feedback(error is StateError ? error.message.toString() : '操作失败，请重试');
      }
    } finally {
      if (_current(epoch)) {
        setState(() {
          _busy = false;
          _busyPackId = null;
        });
      }
    }
  }

  void _feedback(String message) => ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _openDownloads({String? packId}) async {
    final store = _store;
    if (store == null) return;
    final epoch = _accountEpoch;
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => EmojiDownloadScreen(
            store: store,
            initialPackId: packId,
            recentManager: _recentManager)));
    if (_current(epoch)) await _load();
    if (mounted && _current(epoch) && result != null && widget.returnToPicker) {
      Navigator.of(context).pop(result);
    }
  }

  Future<void> _openDetail(EmojiPackInstallation pack) async {
    final store = _store;
    if (store == null) return;
    final epoch = _accountEpoch;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EmojiPackDetailScreen(
              pack: pack,
              store: store,
              recentManager: _recentManager,
              onRepair: pack.trustLevel == EmojiPackTrustLevel.serverOfficial
                  ? () {
                      if (!_current(epoch)) return;
                      Navigator.of(context).pop();
                      unawaited(_openDownloads(packId: pack.packId));
                    }
                  : null,
            )));
    if (_current(epoch)) await _load();
  }

  Future<void> _remove(EmojiPackInstallation pack) async {
    final store = _store;
    final epoch = _accountEpoch;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AnimatedBuilder(
            animation: _recentManager,
            builder: (context, _) => AppAlertDialog(
                  title: const Text('删除本地安装？'),
                  content: Text(_current(epoch)
                      ? '将删除“${pack.name}”的本机文件，历史消息仍会保留。'
                      : '账号已切换，请关闭后重新操作。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: _current(epoch)
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: const Text('删除'))
                  ],
                )));
    if (confirmed == true && _current(epoch)) {
      await _run(() => store.remove(pack.packId), packId: pack.packId);
    }
  }

  void _move(EmojiPackInstallation pack, int offset) {
    final packs = _packs, store = _store;
    if (packs == null || store == null || _busy) return;
    final index = packs.indexWhere((item) => item.packId == pack.packId);
    final next = index + offset;
    if (index < 0 || next < 0 || next >= packs.length) return;
    final ids = packs.map((pack) => pack.packId).toList();
    final id = ids.removeAt(index);
    ids.insert(next, id);
    unawaited(_run(() => store.reorder(ids), packId: pack.packId));
  }

  ImageProvider? _packImage(EmojiPackInstallation pack) => pack
              .manifest.assets.isEmpty ||
          _store == null
      ? null
      : FileImage(File(
          '${_store!.versionDirectory(pack.packId, pack.version).path}/${pack.manifest.assets.first.path}'));

  Widget _packRow(EmojiPackInstallation pack) {
    final index = _packs!.indexOf(pack);
    final epoch = _accountEpoch;
    final damaged = pack.status != EmojiPackInstallStatus.installed;
    final busy = _busyPackId == pack.packId;
    return EmojiPackRow(
      key: ValueKey('managed-pack-${pack.packId}'),
      name: pack.name,
      detail:
          '${pack.manifest.assets.length} 个表情 · ${emojiBytesLabel(pack.totalSize)}',
      cover: EmojiCover(image: _packImage(pack), label: '${pack.name}封面'),
      status: busy
          ? '正在处理…'
          : damaged
              ? '文件损坏，请重新安装'
              : pack.enabled
                  ? '已启用'
                  : '已停用',
      statusIcon: busy
          ? Icons.hourglass_top
          : damaged
              ? Icons.error_outline
              : pack.enabled
                  ? Icons.check_circle_outline
                  : Icons.pause_circle_outline,
      damaged: damaged,
      onTap: _busy ? null : () => unawaited(_openDetail(pack)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          const SizedBox(
              width: 44,
              height: 44,
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))))
        else if (_sorting) ...[
          IconButton(
              tooltip: '${pack.name}上移',
              onPressed: _busy || index == 0 ? null : () => _move(pack, -1),
              icon: const Icon(Icons.arrow_upward, size: 20)),
          IconButton(
              tooltip: '${pack.name}下移',
              onPressed: _busy || index == _packs!.length - 1
                  ? null
                  : () => _move(pack, 1),
              icon: const Icon(Icons.arrow_downward, size: 20)),
        ] else if (damaged &&
            pack.trustLevel == EmojiPackTrustLevel.serverOfficial)
          TextButton(
              onPressed:
                  _busy ? null : () => _openDownloads(packId: pack.packId),
              child: const Text('修复'))
        else
          Semantics(
              label: '启用${pack.name}',
              child: Switch(
                value: pack.enabled,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onChanged: _busy || damaged
                    ? null
                    : (value) {
                        final store = _store!;
                        unawaited(_run(
                            () => store.setEnabled(pack.packId, value),
                            packId: pack.packId));
                      },
              )),
        if (!_sorting)
          AppPopupMenuButton<_PackAction>(
            tooltip: '${pack.name}更多操作',
            enabled: !_busy,
            onOpened: () => _menuOpen = true,
            onCanceled: () => _menuOpen = false,
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) {
              _menuOpen = false;
              if (!_current(epoch)) return;
              switch (action) {
                case _PackAction.preview:
                  unawaited(_openDetail(pack));
                case _PackAction.up:
                  _move(pack, -1);
                case _PackAction.down:
                  _move(pack, 1);
                case _PackAction.rollback:
                  final store = _store!;
                  unawaited(_run(() async {
                    await EmojiPackInstaller(store).rollback(pack.packId);
                  }, packId: pack.packId));
                case _PackAction.remove:
                  unawaited(_remove(pack));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: _PackAction.preview, child: Text('查看表情')),
              PopupMenuItem(
                  value: _PackAction.up,
                  enabled: index > 0,
                  child: const Text('上移')),
              PopupMenuItem(
                  value: _PackAction.down,
                  enabled: index < _packs!.length - 1,
                  child: const Text('下移')),
              if (pack.previous != null)
                const PopupMenuItem(
                    value: _PackAction.rollback, child: Text('回退到上一版')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: _PackAction.remove, child: Text('删除本地安装')),
            ],
          ),
      ]),
    );
  }

  EmojiPreviewItem _favoritePreview(EmojiFavoriteItem item, int index,
      {bool fullSize = false}) {
    final builtin = appStickerById(item.stickerId);
    ImageProvider? image;
    String? name;
    if (builtin != null) {
      image = AssetImage(builtin.thumbnailAsset);
      name = builtin.label;
    }
    if (image == null && item.type == EmojiFavoriteType.sticker) {
      for (final pack in _packs ?? <EmojiPackInstallation>[]) {
        final matches =
            pack.manifest.assets.where((asset) => asset.id == item.stickerId);
        if (matches.isNotEmpty && _store != null) {
          image = FileImage(File(
              '${_store!.versionDirectory(pack.packId, pack.version).path}/${matches.first.path}'));
          name = matches.first.name;
          break;
        }
      }
    }
    image ??= NetworkImage(
      item.type == EmojiFavoriteType.sticker
          ? '${ApiConstants.baseUrl.replaceFirst(RegExp(r'/api/?$'), '')}/stickers/${Uri.encodeComponent(item.stickerId!)}'
          : ApiConstants.fullUrl((fullSize
                  ? item.imageUrl
                  : item.thumbnailUrl) ??
              item.imageUrl ??
              '/api/emoji/favorites/${item.serverId}/${fullSize ? 'file' : 'thumbnail'}'),
      headers: _favoriteHeadersFor(item, fullSize),
    );
    return EmojiPreviewItem(
        id: item.key,
        name: name ?? '收藏图片 ${index + 1}',
        image: image,
        animated: item.isAnimated);
  }

  Map<String, String> _favoriteHeadersFor(
      EmojiFavoriteItem item, bool fullSize) {
    if (item.type == EmojiFavoriteType.sticker) return const {};
    final path =
        (fullSize ? item.imageUrl : item.thumbnailUrl) ?? item.imageUrl;
    final uri = Uri.tryParse(ApiConstants.fullUrl(
        path ?? '/api/emoji/favorites/${item.serverId}/file'));
    final base = Uri.tryParse(ApiConstants.baseUrl);
    final sameOrigin = uri != null &&
        base != null &&
        uri.scheme == base.scheme &&
        uri.host == base.host &&
        uri.port == base.port;
    return sameOrigin ? widget.favoriteHeaders?.call() ?? const {} : const {};
  }

  Future<void> _removeFavorites() async {
    if (_busy || _selected.isEmpty) return;
    final epoch = _accountEpoch;
    final original = List<EmojiFavoriteItem>.from(_favorites ?? []);
    final removed = <(EmojiFavoriteItem, int)>[];
    var failed = 0;
    setState(() => _busy = true);
    for (var i = 0; i < original.length; i++) {
      if (!_current(epoch)) return;
      final item = original[i];
      if (!_selected.contains(item.key)) continue;
      try {
        await _favoriteService.remove(item);
        if (!_current(epoch)) return;
        removed.add((item, i));
        _selected.remove(item.key);
      } catch (_) {
        failed++;
      }
    }
    if (!_current(epoch)) return;
    await _loadFavorites();
    if (!_current(epoch)) return;
    setState(() => _busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(failed == 0
          ? '已移除 ${removed.length} 个收藏'
          : '已移除 ${removed.length} 个，$failed 个未完成，请重试'),
      action: removed.isEmpty
          ? null
          : SnackBarAction(
              label: '撤销',
              onPressed: () async {
                if (!_current(epoch) || _busy) return;
                setState(() => _busy = true);
                var undoFailed = 0;
                for (final entry in removed) {
                  if (!_current(epoch)) return;
                  try {
                    await _favoriteService.undo(entry.$1, index: entry.$2);
                  } catch (_) {
                    undoFailed++;
                  }
                }
                if (!_current(epoch)) return;
                await _loadFavorites();
                if (!_current(epoch)) return;
                setState(() => _busy = false);
                if (undoFailed > 0) _feedback('$undoFailed 个收藏未能恢复，请重试');
              }),
    ));
  }

  Widget _managementTabs() => Row(children: [
        for (final favorite in [false, true])
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.lg),
            child: Semantics(
              button: true,
              selected: _showFavorites == favorite,
              child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    onTap: _busy
                        ? null
                        : () => setState(() => _showFavorites = favorite),
                    child: Container(
                      constraints:
                          const BoxConstraints(minHeight: 48, minWidth: 44),
                      alignment: Alignment.center,
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                      decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: _showFavorites == favorite
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                  width: 2))),
                      child: Text(favorite ? '收藏' : '我的表情包',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                  color: _showFavorites == favorite
                                      ? Theme.of(context).colorScheme.primary
                                      : emojiMuted(context),
                                  fontWeight: _showFavorites == favorite
                                      ? FontWeight.w600
                                      : FontWeight.w400)),
                    ),
                  )),
            ),
          ),
      ]);

  Widget _favoriteCell(EmojiFavoriteItem item, int index) {
    final preview = _favoritePreview(item, index);
    final selected = _selected.contains(item.key);
    final epoch = _accountEpoch;
    final cacheWidth = (100 * MediaQuery.devicePixelRatioOf(context)).ceil();
    return Semantics(
        button: true,
        selected: selected,
        label: '${_selecting ? '选择' : '预览'}${preview.name}',
        child: Material(
          color: emojiSurface(context),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : emojiBorder(context),
                  width: selected ? 2 : 1)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
              key: ValueKey('managed-favorite-${item.key}'),
              onTap: _busy
                  ? null
                  : () {
                      if (_selecting) {
                        setState(() {
                          if (!_selected.add(item.key)) {
                            _selected.remove(item.key);
                          }
                        });
                      } else {
                        unawaited(showEmojiPreview(context,
                            _favoritePreview(item, index, fullSize: true),
                            session: _recentManager,
                            isCurrent: () => _current(epoch)));
                      }
                    },
              child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Column(children: [
                    Expanded(
                        child: Stack(fit: StackFit.expand, children: [
                      Image(
                          image: ResizeImage.resizeIfNeeded(
                              cacheWidth, null, preview.image),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                              Icons.broken_image_outlined,
                              color: emojiMuted(context))),
                      if (_selecting)
                        Align(
                            alignment: Alignment.topRight,
                            child: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                size: 20,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : emojiMuted(context))),
                    ])),
                    const SizedBox(height: AppSpacing.sm),
                    Text(preview.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall),
                    if (item.isAnimated)
                      Text('动图',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: emojiMuted(context))),
                  ]))),
        ));
  }

  Widget _favoriteContent() {
    final items = _favorites;
    return CustomScrollView(
      key: const PageStorageKey('emoji-management-favorites'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
            sliver: SliverToBoxAdapter(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  _managementTabs(),
                  EmojiSectionHeader(
                      title: '我的收藏',
                      detail: items == null ? null : '${items.length} 个收藏',
                      action: TextButton(
                        onPressed: _busy || items == null || items.isEmpty
                            ? null
                            : () => setState(() {
                                  _selecting = !_selecting;
                                  _selected.clear();
                                }),
                        child: Text(_selecting ? '完成' : '选择'),
                      )),
                  if (_favoriteError != null)
                    EmojiInlineError(
                        message: _favoriteError!,
                        onRetry:
                            _busy ? null : () => _loadFavorites(sync: true)),
                  if (items == null && _favoriteError == null)
                    const Padding(
                        padding: EdgeInsets.all(AppSpacing.xxl),
                        child: Center(child: CircularProgressIndicator()))
                  else if (items?.isEmpty == true)
                    EmojiStateView(
                        title: '暂无收藏的表情',
                        detail: '长按聊天中的图片或表情即可收藏。',
                        action: widget.onAddImage == null
                            ? null
                            : OutlinedButton.icon(
                                onPressed: widget.onAddImage,
                                icon: const Icon(
                                    Icons.add_photo_alternate_outlined),
                                label: const Text('添加图片'))),
                ]))),
        if (items?.isNotEmpty == true)
          SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 100,
                    mainAxisExtent:
                        108 + MediaQuery.textScalerOf(context).scale(12),
                    crossAxisSpacing: AppSpacing.sm,
                    mainAxisSpacing: AppSpacing.sm),
                delegate: SliverChildBuilderDelegate(
                    (context, index) => _favoriteCell(items[index], index),
                    childCount: items!.length),
              )),
        SliverPadding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            sliver: SliverToBoxAdapter(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  if (_selecting)
                    OutlinedButton.icon(
                        onPressed: _busy || _selected.isEmpty
                            ? null
                            : _removeFavorites,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.delete_outline),
                        label: Text(
                            '移除已选收藏${_selected.isEmpty ? '' : '（${_selected.length}）'}')),
                  if (!_selecting &&
                      widget.onAddImage != null &&
                      items?.isNotEmpty == true)
                    OutlinedButton.icon(
                        onPressed: _busy ? null : widget.onAddImage,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('添加图片')),
                ]))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final packs = _packs;
    final visible = (packs ?? [])
        .where((pack) => pack.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return EmojiPageScaffold(
      title: '表情管理',
      actions: [
        TextButton(
            onPressed: _store == null || _busy ? null : () => _openDownloads(),
            child: const Text('添加'))
      ],
      body: RefreshIndicator(
          onRefresh: _refresh,
          child: _showFavorites
              ? _favoriteContent()
              : ListView(
                  key: const PageStorageKey('emoji-management-list'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
                  children: [
                    _managementTabs(),
                    EmojiSectionHeader(
                        title: '已安装',
                        detail: packs == null
                            ? null
                            : '${packs.length} 个表情包 · ${emojiBytesLabel(_storageBytes)}',
                        action: TextButton(
                            onPressed:
                                _busy || packs == null || packs.length < 2
                                    ? null
                                    : () => setState(() {
                                          _sorting = !_sorting;
                                          _query = '';
                                        }),
                            child: Text(_sorting ? '完成' : '排序'))),
                    if (!_sorting && packs?.isNotEmpty == true)
                      TextField(
                        key: const ValueKey('emoji-pack-search'),
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                            hintText: '搜索表情包',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            filled: true,
                            fillColor: emojiSurface(context),
                            enabledBorder: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.md),
                                borderSide:
                                    BorderSide(color: emojiBorder(context)))),
                      ),
                    if (_error != null)
                      EmojiInlineError(
                          message: '读取表情包失败，已显示内容会保留',
                          onRetry: _busy ? null : _load),
                    if (packs == null && _error == null)
                      const Padding(
                          padding: EdgeInsets.all(AppSpacing.xxl),
                          child: Center(child: CircularProgressIndicator()))
                    else if (packs?.isEmpty == true)
                      EmojiStateView(
                          title: '暂无已安装的表情包',
                          detail: '内置表情可直接使用，也可以添加官方表情。',
                          action: OutlinedButton.icon(
                              onPressed: _store == null
                                  ? null
                                  : () => _openDownloads(),
                              icon: const Icon(Icons.add),
                              label: const Text('添加表情包')))
                    else if (packs != null) ...[
                      if (visible.isEmpty)
                        const EmojiStateView(
                            title: '没有找到这个表情包', detail: '换个关键词试试。'),
                      for (final pack in visible) ...[
                        _packRow(pack),
                        AppCardDivider(height: 1, color: emojiBorder(context))
                      ],
                    ],
                    const EmojiSectionHeader(title: '系统内置'),
                    EmojiPackRow(
                      name: appStickerGroups.first.name,
                      detail:
                          '${appStickerGroups.first.items.length} 个表情 · 无需下载',
                      status: '内置表情始终可用',
                      statusIcon: Icons.offline_bolt_outlined,
                      cover: EmojiCover(
                          image: AssetImage(appStickerGroups
                              .first.items.first.thumbnailAsset)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => EmojiBuiltinPackPreviewScreen(
                                  group: appStickerGroups.first))),
                    ),
                  ],
                )),
    );
  }
}

class EmojiPackDetailScreen extends StatefulWidget {
  const EmojiPackDetailScreen(
      {super.key,
      required this.pack,
      required this.store,
      this.recentManager,
      this.onRepair});
  final EmojiPackInstallation pack;
  final EmojiPackLocalStore store;
  final EmojiRecentManager? recentManager;
  final VoidCallback? onRepair;
  @override
  State<EmojiPackDetailScreen> createState() => _EmojiPackDetailScreenState();
}

class _EmojiPackDetailScreenState extends State<EmojiPackDetailScreen> {
  late final EmojiRecentManager recentManager;
  late final String? _account;
  bool _invalidated = false;
  EmojiPackInstallation get pack => widget.pack;
  EmojiPackLocalStore get store => widget.store;
  VoidCallback? get onRepair => widget.onRepair;
  @override
  void initState() {
    super.initState();
    recentManager = widget.recentManager ?? EmojiRecentManager.instance;
    _account = recentManager.userId;
    recentManager.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (_account != recentManager.userId) _invalidated = true;
  }

  @override
  void dispose() {
    recentManager.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: recentManager,
      builder: (context, _) {
        final current = !_invalidated && _account == recentManager.userId;
        final items = [
          for (final asset in pack.manifest.assets)
            EmojiPreviewItem(
                id: asset.id,
                name: asset.name,
                image: FileImage(File(
                    '${store.versionDirectory(pack.packId, pack.version).path}/${asset.path}')),
                animated: asset.animated)
        ];
        return EmojiPageScaffold(
            title: current ? pack.name : '表情详情',
            body: current
                ? ListView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    children: [
                      EmojiPackRow(
                          name: pack.name,
                          detail:
                              '${items.length} 个表情 · ${emojiBytesLabel(pack.totalSize)}',
                          status: pack.status == EmojiPackInstallStatus.damaged
                              ? '文件损坏，请重新安装'
                              : pack.enabled
                                  ? '已启用'
                                  : '已停用',
                          damaged:
                              pack.status == EmojiPackInstallStatus.damaged,
                          cover: EmojiCover(
                              size: 72,
                              image: items.isEmpty ? null : items.first.image)),
                      Text('版本 ${pack.version}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: emojiMuted(context))),
                      if (pack.status == EmojiPackInstallStatus.damaged &&
                          onRepair != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.md),
                            child: OutlinedButton.icon(
                                onPressed: onRepair,
                                icon: const Icon(Icons.refresh),
                                label: const Text('重新下载并修复'))),
                      const EmojiSectionHeader(title: '表情内容', detail: '点击查看大图'),
                      if (items.isEmpty)
                        const EmojiStateView(title: '这个表情包还没有内容')
                      else
                        EmojiPreviewGrid(
                            items: items,
                            shrinkWrap: true,
                            onSelected: (item) => showEmojiPreview(
                                context, item,
                                session: recentManager,
                                isCurrent: () =>
                                    !_invalidated &&
                                    _account == recentManager.userId)),
                    ],
                  )
                : const EmojiStateView(title: '账号已切换，请返回'));
      });
}

class EmojiBuiltinPackPreviewScreen extends StatelessWidget {
  const EmojiBuiltinPackPreviewScreen({super.key, required this.group});
  final AppStickerGroup group;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final sticker in group.items)
        EmojiPreviewItem(
            id: sticker.id,
            name: sticker.label,
            image: AssetImage(sticker.thumbnailAsset))
    ];
    return EmojiPageScaffold(
        title: group.name,
        body: ListView(padding: const EdgeInsets.all(AppSpacing.lg), children: [
          EmojiPackRow(
              name: group.name,
              detail: '${items.length} 个表情 · 无需下载',
              status: '系统内置',
              cover: EmojiCover(
                  size: 72, image: items.isEmpty ? null : items.first.image)),
          const EmojiSectionHeader(title: '表情内容', detail: '点击查看大图'),
          EmojiPreviewGrid(items: items, shrinkWrap: true),
        ]));
  }
}
