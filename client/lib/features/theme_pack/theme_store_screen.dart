import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../utils/share_position.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../screens/user_home_screen.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/report_sheet.dart';
import 'theme_appearance.dart';
import 'theme_manifest.dart';
import 'theme_pack_store.dart';
import 'theme_store_repository.dart';
import 'theme_submission_screen.dart';
import 'theme_workshop_samples.dart';

abstract final class ThemeShareLink {
  static final RegExp _uuidExpr = RegExp(
    r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
  );

  static String? parseFamilyId(String rawUri) {
    final uri = Uri.tryParse(rawUri.trim());
    if (uri == null) return null;
    if (uri.scheme == 'sylulive' &&
        uri.host == 'theme' &&
        uri.pathSegments.length == 1) {
      final id = uri.pathSegments.single;
      return _uuidExpr.hasMatch(id) ? id.toLowerCase() : null;
    }
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host == 'sylulive.online' &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'theme') {
      final id = uri.pathSegments[1];
      return _uuidExpr.hasMatch(id) ? id.toLowerCase() : null;
    }
    return null;
  }

  static String buildWebUrl(String familyId) =>
      'https://sylulive.online/theme/${familyId.toLowerCase()}';
}

class ThemeStoreScreen extends StatefulWidget {
  const ThemeStoreScreen({
    super.key,
    this.repository,
    this.downloadManager,
    this.appVersion,
  });

  final ThemeStoreRepository? repository;
  final ThemePackDownloadManager? downloadManager;
  final String? appVersion;

  @override
  State<ThemeStoreScreen> createState() => _ThemeStoreScreenState();
}

class _ThemeStoreScreenState extends State<ThemeStoreScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _sort = 'latest';
  String? _selectedTag;
  String _appliedQuery = '';

  List<ThemeCatalogItem> _items = const [];
  String? _nextCursor;

  bool _loading = true;
  bool _loadingMore = false;
  bool _storeDisabled = false;
  String? _error;
  bool _applyingOriginal = false;

  bool get _showOriginalDefault =>
      (_selectedTag == null ||
          const ['浅色', '深色', '明暗自适应', '简约', '纯色'].contains(_selectedTag)) &&
      '默认主题（经典） 原始外观 官方 内置 青绿 纯色 明暗自适应'.contains(_appliedQuery);

  Map<String, int> _installedVersions = const {};
  Map<String, InstalledTheme> _installedThemes = const {};
  int _loadGeneration = 0;
  CancelToken? _cancelToken;

  ThemeStoreRepository _repo() {
    if (widget.repository != null) return widget.repository!;
    final dio = context.read<AuthProvider>().dio;
    return ThemeStoreRepository(dio);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshAll());
  }

  @override
  void dispose() {
    _cancelToken?.cancel('离开商城页');
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _syncInstalledIndex() async {
    final provider = context.read<ThemeProvider?>();
    if (provider == null) return;
    try {
      final installed = await provider.installedThemes();
      final map = <String, int>{};
      final themes = <String, InstalledTheme>{};
      for (final item in installed) {
        final key = (item.familyId ?? item.manifest.id).toLowerCase();
        final prev = map[key];
        if (prev == null || item.manifest.version > prev) {
          map[key] = item.manifest.version;
          themes[key] = item;
        }
      }
      if (mounted) {
        setState(() {
          _installedVersions = map;
          _installedThemes = themes;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshAll() async {
    final generation = ++_loadGeneration;
    _cancelToken?.cancel('重新加载');
    final token = CancelToken();
    _cancelToken = token;

    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _storeDisabled = false;
    });

    await _syncInstalledIndex();
    if (!mounted || generation != _loadGeneration) return;
    final repo = _repo();
    try {
      final page = await repo.listCatalog(
        sort: _sort,
        tag: _selectedTag,
        query: _appliedQuery,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _items = page.items;
        _nextCursor = page.nextCursor;
        _loading = false;
      });
    } on ThemeStoreDisabledException catch (e) {
      if (!mounted || token.isCancelled || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _storeDisabled = true;
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || token.isCancelled || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _error = '加载主题商城失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (_loading || _loadingMore || cursor == null || cursor.isEmpty) return;
    final generation = _loadGeneration;
    setState(() => _loadingMore = true);
    try {
      final page = await _repo().listCatalog(
        sort: _sort,
        tag: _selectedTag,
        query: _appliedQuery,
        cursor: cursor,
        cancelToken: _cancelToken,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = [..._items, ...page.items];
        _nextCursor = page.nextCursor;
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载更多主题失败，请重试')),
        );
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _openDetail(ThemeCatalogItem item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ThemeDetailScreen(
          familyId: item.familyId,
          initialItem: item,
          repository: widget.repository,
          downloadManager: widget.downloadManager,
          appVersion: widget.appVersion,
        ),
      ),
    );
    if (mounted) await _syncInstalledIndex();
  }

  String? _badgeFor(ThemeCatalogItem item) {
    final installedVer = _installedVersions[item.familyId.toLowerCase()];
    if (installedVer == null) return item.source == 'official' ? '官方' : null;
    if (installedVer < item.version) return '可更新';
    return '已安装';
  }

  Future<void> _applyOriginalDefault() async {
    if (_applyingOriginal) return;
    final provider = context.read<ThemeProvider>();
    setState(() => _applyingOriginal = true);
    try {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
          title: const Text('应用默认主题（经典）？'),
          content: const Text('恢复原始青绿配色、纯色背景、默认字体和布局。应用后可在主题设置中恢复上一个外观。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('应用'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await provider.applyOriginalDefaultAppearance();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已应用默认主题（经典）')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('默认主题未能应用，请重试。')),
        );
      }
    } finally {
      if (mounted) setState(() => _applyingOriginal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final repo = _repo();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: const Text('主题商城'),
        actions: [
          IconButton(
            tooltip: '我的投稿',
            onPressed: _storeDisabled
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MyThemeSubmissionsScreen(
                          repository: widget.repository,
                        ),
                      ),
                    );
                    if (mounted) await _refreshAll();
                  },
            icon: const Icon(Icons.assignment_ind_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: _storeDisabled
                  ? null
                  : () async {
                      final created = await Navigator.of(context).push<Object?>(
                        MaterialPageRoute<Object?>(
                          builder: (_) => ThemeSubmissionScreen(
                            repository: widget.repository,
                            appVersion: widget.appVersion,
                          ),
                        ),
                      );
                      if (created != null && mounted) await _refreshAll();
                    },
              icon: const Icon(Icons.upload_outlined, size: 16),
              label: const Text('投稿'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
                  // 搜索栏 + 排序切换 + 标签筛选
                  SliverToBoxAdapter(
                    child: AppCardSurface(
                      margin: const EdgeInsets.fromLTRB(14, 10, 14, 7),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: tokens.card,
                        border: Border.all(color: tokens.cardBorder),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            key: const ValueKey('theme-store-search-input'),
                            controller: _searchController,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (val) {
                              setState(() => _appliedQuery = val.trim());
                              unawaited(_refreshAll());
                            },
                            decoration: InputDecoration(
                              hintText: '搜索主题名称或风格描述…',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _searchController.text.isEmpty &&
                                      _appliedQuery.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清除搜索',
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _appliedQuery = '');
                                        unawaited(_refreshAll());
                                      },
                                      icon: const Icon(Icons.clear),
                                    ),
                              isDense: true,
                              filled: true,
                              fillColor: tokens.searchFill,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          // 排序与标签合成一行横向滚动，右缘渐隐提示还有更多标签。
                          ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                              colors: [Colors.black, Colors.black, Colors.transparent],
                              stops: [0, .9, 1],
                            ).createShader(rect),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.only(right: 24),
                              child: Row(
                                children: [
                                  _SortToggle(
                                    value: _sort,
                                    onChanged: (val) {
                                      if (_sort == val) return;
                                      setState(() => _sort = val);
                                      unawaited(_refreshAll());
                                    },
                                  ),
                                  Container(
                                    width: 1,
                                    height: 20,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    color: tokens.divider,
                                  ),
                                  _TagPill(
                                    label: '全部',
                                    selected: _selectedTag == null,
                                    onTap: () {
                                      if (_selectedTag == null) return;
                                      setState(() => _selectedTag = null);
                                      unawaited(_refreshAll());
                                    },
                                  ),
                                  for (final tag
                                      in ThemeReviewReasons.allowedTags) ...[
                                    const SizedBox(width: 6),
                                    _TagPill(
                                      label: tag,
                                      selected: _selectedTag == tag,
                                      onTap: () {
                                        setState(
                                          () => _selectedTag =
                                              _selectedTag == tag ? null : tag,
                                        );
                                        unawaited(_refreshAll());
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

            if (!_loading && _error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 42),
                      const SizedBox(height: 8),
                      Text(_error!),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        key: const ValueKey('theme-store-retry'),
                        onPressed: _refreshAll,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_showOriginalDefault || (!_storeDisabled && _items.isNotEmpty))
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final localCount = _showOriginalDefault ? 1 : 0;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount:
                            constraints.crossAxisExtent >= 620 ? 3 : 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.62,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          if (index < localCount) {
                            return _ThemeCatalogCard(
                              key: const ValueKey(
                                  'theme-store-original-default'),
                              name: '默认主题（经典）',
                              subtitle:
                                  _applyingOriginal ? '正在应用…' : '官方 · 恢复原始外观',
                              badge: '内置',
                              preview: IgnorePointer(
                                child: ExcludeSemantics(
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    alignment: Alignment.topCenter,
                                    child: ThemeWorkshopExportStage(
                                      appearance: const ThemeAppearance
                                          .originalDefault(),
                                      brightness: Theme.of(context).brightness,
                                      assetResolver: (_) => null,
                                    ),
                                  ),
                                ),
                              ),
                              onTap: _applyingOriginal
                                  ? null
                                  : _applyOriginalDefault,
                            );
                          }
                          final item = _items[index - localCount];
                          final installed =
                              _installedThemes[item.familyId.toLowerCase()];
                          return _ThemeCatalogCard(
                            name: item.name,
                            subtitle:
                                '${item.source == 'official' ? '官方 · ' : ''}${item.author.nickname} · ${item.downloads} 次下载',
                            preview: _ThemeCover(
                              url: repo.resolveUrl(isDark
                                  ? item.previewDark
                                  : item.previewLight),
                              alignment: Alignment.topCenter,
                              installed: installed?.manifest.version == item.version
                                  ? installed
                                  : null,
                            ),
                            badge: _badgeFor(item),
                            onTap: () => _openDetail(item),
                          );
                        },
                        childCount:
                            localCount + (_storeDisabled ? 0 : _items.length),
                      ),
                    );
                  },
                ),
              ),

            // 在线目录状态不影响内置主题的使用。
            if (_loading && _items.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(14),
                sliver: SliverGrid(
                  key: const ValueKey('theme-store-skeleton'),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.62,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => Container(
                      decoration: BoxDecoration(
                        color: tokens.surfaceMuted,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: tokens.cardBorder),
                      ),
                    ),
                    childCount: 4,
                  ),
                ),
              )
            else if (_error == null && _items.isEmpty && !_showOriginalDefault)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.palette_outlined, size: 44),
                      SizedBox(height: 8),
                      Text('暂无符合条件的主题'),
                    ],
                  ),
                ),
              ),
            if (!_loading && _error == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: _nextCursor != null
                        ? OutlinedButton(
                            key: const ValueKey('theme-store-load-more'),
                            onPressed: _loadingMore ? null : _loadMore,
                            child: Text(
                              _loadingMore ? '加载中…' : '加载更多',
                            ),
                          )
                        : Text(
                            '已加载全部主题',
                            style: TextStyle(
                              fontSize: 12,
                              color: tokens.textTertiary,
                            ),
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SortToggle extends StatelessWidget {
  const _SortToggle({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    Widget option(String key, String label, IconData icon) {
      final selected = value == key;
      return Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? tokens.card : Colors.transparent,
          elevation: selected ? 1 : 0,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () => onChanged(key),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: selected ? colors.primary : tokens.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? tokens.textPrimary : tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: tokens.searchFill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          option('latest', '最新', Icons.schedule_rounded),
          option('popular', '热门', Icons.local_fire_department_outlined),
        ],
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  const _TagPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.primary : Colors.transparent,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? colors.primary : tokens.cardBorder,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? colors.onPrimary : tokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeCatalogCard extends StatelessWidget {
  const _ThemeCatalogCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.preview,
    required this.badge,
    required this.onTap,
  });

  final String name;
  final String subtitle;
  final Widget preview;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    return AppCardSurface(
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tokens.cardBorder),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colors.secondaryContainer.withValues(alpha: .55),
                          tokens.surfaceMuted,
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(14),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .10),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(14),
                          ),
                          child: preview,
                        ),
                      ),
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _CatalogBadge(label: badge!),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tokens.divider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogBadge extends StatelessWidget {
  const _CatalogBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final colors = Theme.of(context).colorScheme;
    final (Color bg, Color fg, IconData? icon) = switch (label) {
      '可更新' => (colors.primary, colors.onPrimary, Icons.arrow_upward_rounded),
      '已安装' => (tokens.card, tokens.success, Icons.check_rounded),
      '官方' => (tokens.card, colors.primary, Icons.verified_rounded),
      _ => (tokens.card, tokens.textPrimary, null),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .10),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 预览图未就绪或加载失败时，画一张抽象的手机界面骨架，避免卡片中间只剩一个图标。
class _PreviewSkeleton extends StatelessWidget {
  const _PreviewSkeleton();

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bar = tokens.textTertiary.withValues(alpha: .16);
    Widget line(double widthFactor, double height) => FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: bar,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
        );
    return ColoredBox(
      color: tokens.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxHeight: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    line(.42, 7),
                    const SizedBox(height: 10),
                    Container(
                      height: 16,
                      decoration: BoxDecoration(
                        color: bar,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                    for (var i = 0; i < 2; i++) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: tokens.surfaceMuted,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            line(.55, 6),
                            const SizedBox(height: 6),
                            line(.9, 5),
                            const SizedBox(height: 4),
                            line(.7, 5),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Icon(
              Icons.palette_outlined,
              size: 18,
              color: tokens.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeCover extends StatelessWidget {
  const _ThemeCover({
    required this.url,
    this.alignment = Alignment.center,
    this.installed,
  });

  final String url;
  final Alignment alignment;
  final InstalledTheme? installed;

  @override
  Widget build(BuildContext context) {
    const placeholder = _PreviewSkeleton();
    Widget remotePreview() => url.isEmpty
        ? placeholder
        : Image.network(
            url,
            fit: BoxFit.cover,
            alignment: alignment,
            excludeFromSemantics: true,
            frameBuilder: (_, child, frame, synchronouslyLoaded) =>
                synchronouslyLoaded || frame != null ? child : placeholder,
            errorBuilder: (_, __, ___) => placeholder,
          );
    final local = installed;
    if (local == null) return remotePreview();
    final mode = Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';
    final preview = (local.manifest.data['preview'] as Map)[mode] as String;
    return Image.file(
      File('${local.directory}/$preview'),
      fit: BoxFit.cover,
      alignment: alignment,
      excludeFromSemantics: true,
      errorBuilder: (_, __, ___) => remotePreview(),
    );
  }
}

class ThemeDetailScreen extends StatefulWidget {
  const ThemeDetailScreen({
    super.key,
    required this.familyId,
    this.initialItem,
    this.repository,
    this.downloadManager,
    this.appVersion,
    this.onShareLink,
  });

  final String familyId;
  final ThemeCatalogItem? initialItem;
  final ThemeStoreRepository? repository;
  final ThemePackDownloadManager? downloadManager;
  final String? appVersion;
  final Future<void> Function(String url)? onShareLink;

  @override
  State<ThemeDetailScreen> createState() => _ThemeDetailScreenState();
}

class _ThemeDetailScreenState extends State<ThemeDetailScreen> {
  final PageController _previewController = PageController();
  int _previewPage = 0;

  ThemeCatalogItem? _item;
  bool _loading = true;
  bool _notFound = false;
  String? _error;
  bool _busyAction = false;
  String _currentAppVersion = '1.0.0';

  InstalledTheme? _installedExact;
  InstalledTheme? _installedFamily;

  ThemePackDownloadManager? _downloader;
  CancelToken? _detailCancelToken;

  ThemeStoreRepository _repo() {
    if (widget.repository != null) return widget.repository!;
    final dio = context.read<AuthProvider>().dio;
    return ThemeStoreRepository(dio);
  }

  ThemePackDownloadManager _resolveDownloader(ThemeProvider provider) {
    return widget.downloadManager ??
        ThemePackDownloadManager.shared(provider.themePacks, _repo());
  }

  @override
  void initState() {
    super.initState();
    _item = widget.initialItem;
    if (_item != null) _loading = false;
    unawaited(_initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<ThemeProvider?>();
    if (provider != null) {
      final dl = _resolveDownloader(provider);
      if (_downloader != dl) {
        _downloader?.removeListener(_onDownloadChanged);
        _downloader = dl..addListener(_onDownloadChanged);
      }
    }
  }

  @override
  void dispose() {
    _detailCancelToken?.cancel('离开详情页');
    _downloader?.removeListener(_onDownloadChanged);
    _previewController.dispose();
    super.dispose();
  }

  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    _currentAppVersion = widget.appVersion ?? await _readPlatformVersion();
    await _loadDetail();
    await _refreshLocalInstallState();
  }

  Future<String> _readPlatformVersion() async {
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

  Future<void> _loadDetail() async {
    _detailCancelToken?.cancel('重新请求详情');
    final token = CancelToken();
    _detailCancelToken = token;
    setState(() {
      if (_item == null) _loading = true;
      _error = null;
      _notFound = false;
    });
    try {
      final detail = await _repo().getDetail(
        widget.familyId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _item = detail;
        _loading = false;
      });
    } on ThemeStoreApiException catch (e) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        if (e.code == 'theme_not_found' || e.statusCode == 404) {
          _notFound = true;
          _item = null;
        } else {
          _error = e.message;
        }
      });
    } catch (_) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        if (_item == null) _error = '加载主题详情失败，请重试';
      });
    }
  }

  Future<void> _refreshLocalInstallState() async {
    final provider = context.read<ThemeProvider?>();
    final item = _item;
    if (provider == null || item == null) return;
    final exact = await provider.themePacks.findInstalledVersion(
      item.familyId,
      item.version,
    );
    final list = await provider.installedThemes();
    InstalledTheme? familyMatch;
    for (final inst in list) {
      final fid = (inst.familyId ?? inst.manifest.id).toLowerCase();
      if (fid == item.familyId.toLowerCase()) {
        if (familyMatch == null ||
            inst.manifest.version > familyMatch.manifest.version) {
          familyMatch = inst;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _installedExact = exact;
      _installedFamily = familyMatch;
    });
  }

  Future<void> _downloadAndApply() async {
    if (_busyAction || _item == null) return;
    final item = _item!;
    final provider = context.read<ThemeProvider>();
    final downloader = _resolveDownloader(provider);

    setState(() => _busyAction = true);
    try {
      final installed = await downloader.downloadAndInstall(
        item: item,
        provider: provider,
        appVersion: _currentAppVersion,
      );
      await provider.applyInstalledTheme(installed, ThemeGroup.defaultApply);
      await _refreshLocalInstallState();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已应用《${item.name}》')),
        );
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下载失败，请检查网络后重试')),
        );
      }
    } on ThemePackError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('安装主题失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _applyAlreadyInstalled() async {
    if (_busyAction || _installedExact == null) return;
    setState(() => _busyAction = true);
    try {
      await context.read<ThemeProvider>().applyInstalledTheme(
            _installedExact!,
            ThemeGroup.defaultApply,
          );
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _startStoreTrial() async {
    if (_busyAction || _item == null) return;
    final item = _item!;
    final provider = context.read<ThemeProvider>();
    final downloader = _resolveDownloader(provider);

    setState(() => _busyAction = true);
    try {
      final installed = _installedExact ??
          await downloader.downloadAndInstall(
            item: item,
            provider: provider,
            appVersion: _currentAppVersion,
          );
      await _refreshLocalInstallState();
      await provider.startTrial(
        installed: installed,
        groups: ThemeGroup.defaultApply,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('正在试用《${item.name}》，离开此页后仍可跨页面体验'),
          ),
        );
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下载试用包失败，请重试')),
        );
      }
    } on ThemePackError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _shareLink(ThemeCatalogItem item) async {
    final link = ThemeShareLink.buildWebUrl(item.familyId);
    if (widget.onShareLink != null) {
      await widget.onShareLink!(link);
      return;
    }
    await Share.share('来看看这套沈理校园主题《${item.name}》：$link',
        sharePositionOrigin: sharePosition(context));
  }

  void _openFullScreenPreview(List<String> urls, int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('预览大图'),
          ),
          body: PageView.builder(
            controller: PageController(initialPage: initialIndex),
            itemCount: urls.length,
            itemBuilder: (_, idx) => InteractiveViewer(
              child: Center(
                child: Image.network(
                  urls[idx],
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider?>();
    final tokens = AppThemeTokens.of(context);
    final item = _item;

    return Scaffold(
      appBar: AppBar(
        title: Text(item?.name ?? '主题详情'),
        actions: [
          if (item != null)
            PopupMenuButton<String>(
              key: const ValueKey('theme-detail-more-menu'),
              onSelected: (action) {
                if (action == 'share') {
                  unawaited(_shareLink(item));
                } else if (action == 'report') {
                  showReportSheet(
                    context,
                    targetType: 'theme',
                    targetKey: item.familyId,
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'share', child: Text('分享链接')),
                PopupMenuItem(value: 'report', child: Text('举报')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notFound
              ? const Center(
                  key: ValueKey('theme-detail-not-found'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.remove_circle_outline, size: 48),
                      SizedBox(height: 10),
                      Text('主题不存在或已下架'),
                    ],
                  ),
                )
              : _error != null && item == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: _loadDetail,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : _buildContent(context, item!, tokens, provider),
      bottomNavigationBar: item == null
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: tokens.surface,
                  border: Border(top: BorderSide(color: tokens.divider)),
                ),
                child: _buildBottomBar(context, item, provider),
              ),
            ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeCatalogItem item,
    AppThemeTokens tokens,
    ThemeProvider? provider,
  ) {
    final repo = _repo();
    final previewUrls = [
      repo.resolveUrl(item.previewLight),
      repo.resolveUrl(item.previewDark),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AppCardSurface(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: tokens.cardBorder),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Theme.of(context).colorScheme.secondaryContainer, tokens.card],
                ),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 320,
                    child: PageView.builder(
                      controller: _previewController,
                      onPageChanged: (idx) => setState(() => _previewPage = idx),
                      itemCount: 2,
                      itemBuilder: (context, idx) => Center(
                        child: AspectRatio(
                          aspectRatio: 1080 / 2340,
                          child: Material(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                              side: BorderSide(color: tokens.cardBorder),
                            ),
                            elevation: 4,
                            clipBehavior: Clip.antiAlias,
                            child: Semantics(
                              button: true,
                              label: idx == 0 ? '全屏查看浅色预览' : '全屏查看深色预览',
                              child: InkWell(
                                onTap: () => _openFullScreenPreview(previewUrls, idx),
                                child: _ThemeCover(url: previewUrls[idx]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (var idx = 0; idx < 2; idx++)
                        ChoiceChip(
                          avatar: Icon(
                            idx == 0 ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                            size: 16,
                          ),
                          label: Text(idx == 0 ? '浅色预览' : '深色预览'),
                          selected: _previewPage == idx,
                          onSelected: (_) {
                            if (MediaQuery.disableAnimationsOf(context)) {
                              _previewController.jumpToPage(idx);
                            } else {
                              _previewController.animateToPage(
                                idx,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AppCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (item.isOfficial)
                        const Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('官方主题'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 可点击进入作者个人主页
                  InkWell(
                    key: const ValueKey('theme-detail-author-row'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: item.author.id <= 0
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    UserHomeScreen(userId: item.author.id),
                              ),
                            ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.person_outline, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.author.nickname,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: tokens.primary,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: tokens.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Text('版本 v${item.version}',
                          style: const TextStyle(fontSize: 12.5)),
                      Text(
                        '大小 ${ThemeReviewReasons.formatBytes(item.packageSize)}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      Text(ThemeReviewReasons.licenseLabel(item.license),
                          style: const TextStyle(fontSize: 12.5)),
                      Text('下载 ${item.downloads}',
                          style: const TextStyle(fontSize: 12.5)),
                      Text('要求 App ≥ ${item.minAppVersion}',
                          style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                  if (item.tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in item.tags)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(tag),
                          ),
                      ],
                    ),
                  ],
                  if (item.description.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      item.description,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                    ),
                  ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    ThemeCatalogItem item,
    ThemeProvider? provider,
  ) {
    final activeTask = _downloader?.activeTaskForFamily(item.familyId);

    // 状态 2：下载中（进度 + 取消）
    if (activeTask != null) {
      final pct = activeTask.progress == null
          ? ''
          : ' ${(activeTask.progress! * 100).round()}%';
      return Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  activeTask.status == ThemeDownloadStatus.installing
                      ? '正在安装…'
                      : '下载中$pct',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: activeTask.progress),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            key: const ValueKey('theme-detail-cancel-download'),
            onPressed: () => unawaited(
              _downloader!.cancel(item.familyId, activeTask.version),
            ),
            child: const Text('取消'),
          ),
        ],
      );
    }

    // 状态 6：App 版本过低
    if (ThemeReviewReasons.compareSemver(
          _currentAppVersion,
          item.minAppVersion,
        ) <
        0) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('theme-detail-state-too-old'),
          onPressed: null,
          child: Text('需要更新 App（最低 ${item.minAppVersion}）'),
        ),
      );
    }

    // 状态 5：有新版本
    if (_installedFamily != null &&
        _installedFamily!.manifest.version < item.version) {
      return Row(
        children: [
          OutlinedButton(
            key: const ValueKey('theme-detail-trial-button'),
            onPressed: _busyAction ? null : _startStoreTrial,
            child: const Text('试用新版'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              key: const ValueKey('theme-detail-state-update'),
              onPressed: _busyAction ? null : _downloadAndApply,
              child: Text('更新（v${_installedFamily!.manifest.version} → v${item.version}）'),
            ),
          ),
        ],
      );
    }

    // 状态 4：正在使用
    final isActive =
        provider?.isThemeVersionActive(item.familyId, item.version) == true;
    if (isActive) {
      return const SizedBox(
        width: double.infinity,
        child: FilledButton.tonal(
          key: ValueKey('theme-detail-state-active'),
          onPressed: null,
          child: Text('已应用'),
        ),
      );
    }

    // 状态 3：已安装但未使用
    if (_installedExact != null) {
      return Row(
        children: [
          OutlinedButton(
            key: const ValueKey('theme-detail-trial-button'),
            onPressed: _busyAction ? null : _startStoreTrial,
            child: const Text('试用'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              key: const ValueKey('theme-detail-state-apply'),
              onPressed: _busyAction ? null : _applyAlreadyInstalled,
              child: const Text('应用'),
            ),
          ),
        ],
      );
    }

    // 状态 1：未安装（下载并应用 + 试用）
    return Row(
      children: [
        OutlinedButton(
          key: const ValueKey('theme-detail-trial-button'),
          onPressed: _busyAction ? null : _startStoreTrial,
          child: const Text('试用'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            key: const ValueKey('theme-detail-download-apply-button'),
            onPressed: _busyAction ? null : _downloadAndApply,
            child: const Text('下载并应用'),
          ),
        ),
      ],
    );
  }
}
