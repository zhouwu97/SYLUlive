import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../services/emoji_favorite_repository.dart';
import '../../services/emoji_favorite_service.dart';
import '../../theme/app_motion.dart';
import 'emoji_catalog.dart';
import 'sticker_catalog.dart';

/// 内嵌式表情选择面板。
///
/// 页面从左到右依次为收藏、普通 Emoji 和各个表情包。点击底部标签或
/// 横向滑动都能切换页面；具体发送策略由聊天或评论页面决定。
class AppEmojiPanel extends StatefulWidget {
  final ValueChanged<String> onEmojiSelected;
  final VoidCallback onBackspace;
  final ValueChanged<AppSticker>? onStickerSelected;
  final ValueChanged<EmojiFavoriteItem>? onFavoriteImageSelected;
  final VoidCallback? onAddImage;
  final ValueChanged<EmojiFavoriteItem>? onFavoriteRemoved;
  final ValueChanged<EmojiFavoriteItem>? onFavoriteUndo;
  final Map<String, String> favoriteImageHeaders;
  final bool enabled;
  final EmojiFavoriteService? favoriteService;

  const AppEmojiPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onBackspace,
    this.onStickerSelected,
    this.onFavoriteImageSelected,
    this.onAddImage,
    this.onFavoriteRemoved,
    this.onFavoriteUndo,
    this.favoriteImageHeaders = const <String, String>{},
    this.enabled = true,
    this.favoriteService,
  });

  @override
  State<AppEmojiPanel> createState() => _AppEmojiPanelState();
}

class _AppEmojiPanelState extends State<AppEmojiPanel> {
  static const int _favoriteTabIndex = 0;
  static const int _emojiTabIndex = 1;
  static const int _stickerTabStartIndex = 2;

  late final PageController _pageController;
  late final ScrollController _tabScrollController;
  late final EmojiFavoriteService _favoriteService;

  int _tabIndex = _favoriteTabIndex;
  List<EmojiFavoriteItem> _favorites = const [];

  int get _tabCount =>
      _stickerTabStartIndex +
      (widget.onStickerSelected == null ? 0 : appStickerGroups.length);

  List<EmojiFavoriteItem> get _visibleFavorites => _favorites.where((item) {
        if (item.type == EmojiFavoriteType.image) {
          return item.imageUrl?.isNotEmpty == true || item.fileId != null;
        }
        return appStickerById(item.stickerId) != null;
      }).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _tabScrollController = ScrollController();
    _favoriteService = widget.favoriteService ?? EmojiFavoriteService.instance;
    _favoriteService.addListener(_handleFavoritesChanged);
    unawaited(_loadFavorites());
  }

  @override
  void dispose() {
    _favoriteService.removeListener(_handleFavoritesChanged);
    _pageController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  void _handleFavoritesChanged() {
    unawaited(_loadFavorites());
  }

  Future<void> _loadFavorites() async {
    final favorites = await _favoriteService.load();
    if (mounted) setState(() => _favorites = favorites);
  }

  void _selectTab(int index) {
    if (index < 0 || index >= _tabCount) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(index);
      return;
    }
    _pageController.animateToPage(
      index,
      duration: AppMotion.tab,
      curve: AppMotion.incoming,
    );
  }

  void _handlePageChanged(int index) {
    setState(() => _tabIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tabScrollController.hasClients) return;
      final target = (index * 48.0 - 52.0).clamp(
        0.0,
        _tabScrollController.position.maxScrollExtent,
      );
      if (MediaQuery.disableAnimationsOf(context)) {
        _tabScrollController.jumpTo(target);
        return;
      }
      _tabScrollController.animateTo(
        target,
        duration: AppMotion.fast,
        curve: AppMotion.incoming,
      );
    });
  }

  Future<void> _toggleStickerFavorite(AppSticker sticker) async {
    if (!widget.enabled) return;
    final added = await _favoriteService.toggleSticker(sticker.id);
    if (mounted) _showFavoriteFeedback(added);
  }

  Future<void> _removeFavorite(EmojiFavoriteItem item) async {
    if (!widget.enabled) return;
    final index = _favorites.indexWhere((entry) => entry.key == item.key);
    try {
      await _favoriteService.remove(item);
    } on EmojiFavoriteException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
      return;
    }
    widget.onFavoriteRemoved?.call(item);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已从收藏移除'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              unawaited(_undoFavorite(item, index));
            },
          ),
        ),
      );
  }

  Future<void> _undoFavorite(EmojiFavoriteItem item, int index) async {
    try {
      await _favoriteService.undo(item, index: index);
    } on EmojiFavoriteException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
      return;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('撤销收藏失败')),
        );
      }
      debugPrint('撤销表情收藏失败: $error');
      return;
    }
    widget.onFavoriteUndo?.call(item);
    if (mounted) _showFavoriteFeedback(true);
  }

  void _showFavoriteFeedback(bool added) {
    if (Scaffold.maybeOf(context) == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(added ? '已添加到收藏' : '已取消收藏'),
          duration: const Duration(milliseconds: 900),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C202A) : const Color(0xFFF8F9FC);
    final muted = isDark ? Colors.white60 : Colors.black54;

    return Material(
      color: surface,
      child: Column(
        children: [
          Expanded(
            child: PageView.builder(
              key: const ValueKey('emoji-page-view'),
              controller: _pageController,
              itemCount: _tabCount,
              onPageChanged: _handlePageChanged,
              itemBuilder: (context, index) {
                if (index == _favoriteTabIndex) {
                  return _buildFavoriteGrid(muted);
                }
                if (index == _emojiTabIndex) {
                  return _buildEmojiGrid();
                }
                return _buildStickerGrid(
                  appStickerGroups[index - _stickerTabStartIndex],
                  muted,
                );
              },
            ),
          ),
          _buildBottomTabs(theme, isDark, muted),
        ],
      ),
    );
  }

  Widget _buildFavoriteGrid(Color muted) {
    final favorites = _visibleFavorites;

    if (favorites.isEmpty) {
      return Stack(
        children: [
          GridView.builder(
            key: const ValueKey('emoji-favorite-grid'),
            padding: const EdgeInsets.all(10),
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisExtent: 72,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: 1,
            itemBuilder: (context, index) => _buildAddImageCell(muted),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                // 上下对称留白，让空态以整个内容区为基准居中。
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: _buildFavoriteEmptyState(muted),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            key: const ValueKey('emoji-favorite-grid'),
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisExtent: 72,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: favorites.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _buildAddImageCell(muted);
              final item = favorites[index - 1];
              return _buildFavoriteCell(item, muted);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFavoriteEmptyState(Color muted) {
    return Semantics(
      liveRegion: true,
      label: '暂无收藏的表情，长按图片或表情即可添加',
      child: Column(
        key: const ValueKey('emoji-favorite-empty-state'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.favorite_border_rounded, size: 28, color: muted),
          const SizedBox(height: 4),
          Text('暂无收藏的表情', style: TextStyle(color: muted, fontSize: 13)),
          const SizedBox(height: 2),
          Text(
            '长按图片或表情即可添加',
            style: TextStyle(
              color: muted.withValues(alpha: 0.72),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddImageCell(Color muted) {
    return Semantics(
      button: true,
      label: '添加图片到表情包',
      child: Tooltip(
        message: '添加图片',
        child: InkWell(
          key: const ValueKey('emoji-add-image'),
          onTap: widget.enabled ? widget.onAddImage : null,
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Center(
              child: Icon(
                Icons.add_rounded,
                size: 36,
                color: muted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFavoriteCell(EmojiFavoriteItem item, Color muted) {
    final sticker = item.type == EmojiFavoriteType.sticker
        ? appStickerById(item.stickerId)
        : null;
    final label = sticker?.label ?? (item.isAnimated ? '收藏图片（GIF 动图）' : '收藏图片');
    return Semantics(
      button: true,
      label: '发送$label',
      child: InkWell(
        key: ValueKey('favorite-${item.key}'),
        onTap: widget.enabled
            ? () {
                if (sticker != null) {
                  widget.onStickerSelected?.call(sticker);
                } else {
                  widget.onFavoriteImageSelected?.call(item);
                }
              }
            : null,
        onLongPress: widget.enabled ? () => _removeFavorite(item) : null,
        borderRadius: BorderRadius.circular(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.35),
            child: sticker != null
                ? Padding(
                    padding: const EdgeInsets.all(5),
                    child: Image.asset(
                      sticker.thumbnailAsset,
                      fit: BoxFit.contain,
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: ApiConstants.fullUrl(_favoriteImagePath(item)),
                    httpHeaders: widget.favoriteImageHeaders,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) =>
                        Icon(Icons.broken_image_outlined, color: muted),
                  ),
          ),
        ),
      ),
    );
  }

  String _favoriteImagePath(EmojiFavoriteItem item) {
    final path = item.thumbnailUrl ?? item.imageUrl;
    if (path?.isNotEmpty == true) return path!;
    final id = item.serverId;
    return id == null ? '' : '/emoji/favorites/$id/thumbnail';
  }

  Widget _buildEmojiGrid() {
    final emojis = appEmojiCatalog['表情']!;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 56,
        mainAxisExtent: 48,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, index) {
        final emoji = emojis[index];
        return Semantics(
          button: true,
          label: '插入表情 $emoji',
          child: InkWell(
            onTap: widget.enabled ? () => widget.onEmojiSelected(emoji) : null,
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: Text(
                emoji,
                style: const TextStyle(
                  fontSize: 28,
                  fontFamilyFallback: [
                    'Noto Color Emoji',
                    'Segoe UI Emoji',
                    'Apple Color Emoji',
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStickerGrid(AppStickerGroup group, Color muted) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  group.name,
                  key: ValueKey('sticker-pack-title-${group.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '共 ${group.items.length} 个',
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            key: ValueKey('sticker-group-${group.id}'),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisExtent: 88,
              mainAxisSpacing: 4,
              crossAxisSpacing: 2,
            ),
            itemCount: group.items.length,
            itemBuilder: (context, index) {
              final sticker = group.items[index];
              final isFavorite = _favorites.any(
                (item) =>
                    item.type == EmojiFavoriteType.sticker &&
                    item.stickerId == sticker.id,
              );
              return Semantics(
                button: true,
                label: '发送表情 ${sticker.label}',
                child: InkWell(
                  key: ValueKey('sticker-${sticker.id}'),
                  onTap: widget.enabled
                      ? () => widget.onStickerSelected?.call(sticker)
                      : null,
                  onLongPress: widget.enabled
                      ? () => _toggleStickerFavorite(sticker)
                      : null,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(3, 3, 3, 1),
                    child: Column(
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.asset(
                                sticker.thumbnailAsset,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => Icon(
                                  Icons.broken_image_outlined,
                                  color: muted,
                                ),
                              ),
                              if (isFavorite)
                                const Positioned(
                                  top: 0,
                                  right: 0,
                                  child: Icon(
                                    Icons.favorite_rounded,
                                    size: 14,
                                    color: Color(0xFFFF5C7A),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sticker.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBottomTabs(
    ThemeData theme,
    bool isDark,
    Color muted,
  ) {
    final divider =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE8EAF0);
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        border: Border(top: BorderSide(color: divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _tabScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              itemCount: _tabCount,
              itemBuilder: (context, index) => _buildTab(
                theme: theme,
                muted: muted,
                index: index,
              ),
            ),
          ),
          SizedBox(
            width: 46,
            child: Tooltip(
              message: '删除前一个字符',
              child: IconButton(
                key: const ValueKey('emoji-backspace-button'),
                onPressed: widget.enabled ? widget.onBackspace : null,
                icon: const Icon(Icons.backspace_outlined),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab({
    required ThemeData theme,
    required Color muted,
    required int index,
  }) {
    final selected = _tabIndex == index;
    final selectedColor = theme.colorScheme.primary;
    final background =
        selected ? selectedColor.withValues(alpha: 0.12) : Colors.transparent;

    Widget icon;
    Key key;
    String tooltip;
    if (index == _favoriteTabIndex) {
      key = const ValueKey('emoji-tab-favorite');
      tooltip = '收藏';
      icon = Icon(
        selected ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: 24,
        color: selected ? selectedColor : muted,
      );
    } else if (index == _emojiTabIndex) {
      key = const ValueKey('emoji-tab-face');
      tooltip = '普通表情';
      icon = Icon(
        Icons.sentiment_satisfied_alt_rounded,
        size: 25,
        color: selected ? selectedColor : muted,
      );
    } else {
      final group = appStickerGroups[index - _stickerTabStartIndex];
      key = ValueKey('sticker-pack-tab-${group.id}');
      tooltip = group.name;
      icon = Image.asset(
        group.items.first.thumbnailAsset,
        width: 36,
        height: 36,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(Icons.image_outlined, color: muted),
      );
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: widget.enabled ? () => _selectTab(index) : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 46,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: icon,
        ),
      ),
    );
  }
}
