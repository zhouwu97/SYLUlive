import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/canteen_share_link.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/canteen/admin_dish_actions.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/dish_photo_mosaic.dart';
import '../widgets/canteen/dish_review_tile.dart';
import 'canteen_dish_reviews_screen.dart';
import 'canteen_review_editor_screen.dart';

/// 菜品详情页：三维评分（味道 / 性价比 / 分量）+ 同学评价 + 最新实拍 + 评价入口。
///
/// 实拍没有名额上限，服务端只返回最新几张（管理员设定的封面排在最前），
/// 所以这里始终保留“评价这道菜”的入口，旧图会被新图自然替换。
class CanteenDishDetailScreen extends StatefulWidget {
  final int canteenId;
  final int dishId;
  final String dishName;
  final String canteenName;

  const CanteenDishDetailScreen({
    super.key,
    required this.canteenId,
    required this.dishId,
    required this.dishName,
    required this.canteenName,
  });

  @override
  State<CanteenDishDetailScreen> createState() =>
      _CanteenDishDetailScreenState();
}

enum _AdminDishMenu { rename, hide, merge }

/// 菜品页内容宽度：手机上左右 16，平板和桌面上内容居中、最宽 720，
/// 评分条和评价正文不会被拉得过长。
EdgeInsets dishPagePadding(BuildContext context,
    {double top = 0, double bottom = 0}) {
  const maxWidth = 720.0;
  final width = MediaQuery.sizeOf(context).width;
  final side = width > maxWidth + 32 ? (width - maxWidth) / 2 : 16.0;
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

class _CanteenDishDetailScreenState extends State<CanteenDishDetailScreen> {
  static const _previewReviewCount = 3;

  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _reviews = [];
  int _reviewTotal = 0;
  bool _reviewsFailed = false;
  bool _isLoading = true;
  String? _loadError;
  late String _dishName;
  int _generation = 0;
  final Set<String> _failedPhotoImages = <String>{};

  @override
  void initState() {
    super.initState();
    _dishName = widget.dishName;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _isLoading = _data == null;
      _loadError = null;
    });
    final provider = context.read<CanteenProvider>();
    // 两个请求并行且共用 provider.errorMessage，详情的错误必须在它完成的当下取走，
    // 否则会被评价请求的结果覆盖。
    final detailFuture = provider
        .loadDishDetail(widget.canteenId, widget.dishId)
        .then((data) => (data: data, error: provider.errorMessage));
    final reviewsFuture =
        provider.loadDishReviewPage(widget.dishId, limit: _previewReviewCount);
    final detail = await detailFuture;
    final reviews = await reviewsFuture;
    if (!mounted || generation != _generation) return;
    final data = detail.data;
    setState(() {
      _isLoading = false;
      if (data == null) {
        _loadError = detail.error ?? '菜品加载失败，请检查网络后重试';
        return;
      }
      _data = data;
      final dish = data['dish'];
      if (dish is Map && dish['name']?.toString().trim().isNotEmpty == true) {
        _dishName = dish['name'].toString();
      }
      _reviewsFailed = reviews == null;
      _reviews = reviews?.items.take(_previewReviewCount).toList() ?? [];
      _reviewTotal = reviews?.total ?? 0;
    });
  }

  // ── 派生数据 ────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _photos =>
      (_data?['photos'] as List?)
          ?.whereType<Map>()
          .map((photo) => Map<String, dynamic>.from(photo))
          .toList(growable: false) ??
      const [];

  List<Map<String, dynamic>> get _visiblePhotos => _photos.where((photo) {
        final image = photo['image']?.toString().trim() ?? '';
        return image.isNotEmpty && !_failedPhotoImages.contains(image);
      }).toList(growable: false);

  List<String> get _photoImages => _visiblePhotos
      .map((photo) => photo['image'].toString().trim())
      .toList(growable: false);

  /// 实拍总数：服务端总数减去本页确认无效的图片（空地址或文件已丢失）。
  int get _photoTotal {
    final serverTotal = (_data?['photo_count'] as num?)?.toInt() ?? 0;
    final invalid = _photos.length - _visiblePhotos.length;
    final total = serverTotal - invalid;
    return total < _visiblePhotos.length ? _visiblePhotos.length : total;
  }

  int get _mentionCount =>
      (_data?['mention_count'] as num?)?.toInt() ??
      (_data?['reviewer_count'] as num?)?.toInt() ??
      _reviewTotal;

  int get _ratedCount => (_data?['rated_count'] as num?)?.toInt() ?? 0;

  double _score(String key) {
    final scores = _data?['scores'];
    return scores is Map ? (scores[key] as num?)?.toDouble() ?? 0 : 0;
  }

  bool get _isOffline {
    final dish = _data?['dish'];
    if (dish is! Map) return false;
    return dish['canteen_operating_status']?.toString() == 'offline';
  }

  // ── 操作 ────────────────────────────────────────────────────────

  Future<void> _openReviewEditor() async {
    final auth = context.read<AuthProvider>();
    if (_isOffline) {
      AppFeedback.info('所属商家已下架，暂不能评价', context: context);
      return;
    }
    if (!auth.isLoggedIn) {
      AppFeedback.info('请先登录后评价', context: context);
      return;
    }
    if (auth.user?.studentVerified != true) {
      AppFeedback.info('请先绑定教务账号后再评价', context: context);
      return;
    }
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CanteenReviewEditorScreen(
          canteenId: widget.canteenId,
          canteenName: widget.canteenName,
          mode: CanteenReviewEditorMode.create,
          initialDishId: widget.dishId,
          initialDishName: _dishName,
        ),
      ),
    );
    if (published == true && mounted) await _load();
  }

  Future<void> _share() async {
    final text = canteenShareText(
      canteenId: widget.canteenId,
      name: widget.canteenName,
      dishName: _dishName,
      averageStar: _score('average'),
      ratingCount: _ratedCount,
    );
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    try {
      await Share.share(text,
          subject: '$_dishName - 沈理校园餐饮', sharePositionOrigin: origin);
    } catch (_) {
      if (!mounted) return;
      AppFeedback.error('暂时无法调起分享，请稍后重试', context: context);
    }
  }

  Future<void> _openAllReviews() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CanteenDishReviewsScreen(
          dishId: widget.dishId,
          dishName: _dishName,
        ),
      ),
    );
  }

  Future<void> _onAdminMenu(_AdminDishMenu action) async {
    switch (action) {
      case _AdminDishMenu.rename:
        final renamed = await showAdminRenameDishDialog(
          context,
          dishId: widget.dishId,
          currentName: _dishName,
        );
        if (renamed && mounted) await _load();
      case _AdminDishMenu.hide:
        final hidden = await showAdminToggleDishVisibilityDialog(
          context,
          dishId: widget.dishId,
          dishName: _dishName,
          currentlyHidden: false,
        );
        // 隐藏后这道菜不再公开，详情页没有可展示的内容了。
        if (hidden && mounted) Navigator.of(context).pop(true);
      case _AdminDishMenu.merge:
        final merged = await showAdminMergeDishFlow(
          context,
          canteenId: widget.canteenId,
          sourceDishId: widget.dishId,
          sourceDishName: _dishName,
        );
        if (merged && mounted) Navigator.of(context).pop(true);
    }
  }

  Future<void> _handleAdminManagePhoto(int index) async {
    final photos = _visiblePhotos;
    if (index < 0 || index >= photos.length) return;
    final photo = photos[index];
    final photoId = (photo['id'] as num?)?.toInt();
    if (photoId == null) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final initialUploaderName =
        photo['uploader_name'] ?? photo['nickname'] ?? '同学';
    final initialCreatedAt = photo['created_at']?.toString() ?? '';

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => FutureBuilder<Map<String, dynamic>?>(
        future:
            context.read<CanteenProvider>().adminGetDishPhotoDetail(photoId),
        builder: (ctx, snapshot) {
          final detail = snapshot.data;
          final uploaderName = detail?['uploader_name'] ?? initialUploaderName;
          final createdAt =
              detail?['created_at']?.toString() ?? initialCreatedAt;

          return AppCardSurface(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: CanteenTheme.surfaceBg(isDark),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: CanteenTheme.borderColor(isDark),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '管理已发布实拍',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: CanteenTheme.textPrimaryColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '上传者：$uploaderName${createdAt.isNotEmpty ? ' · $createdAt' : ''}',
                    style: TextStyle(
                      fontSize: 13,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(sheetCtx, 'cover'),
                    icon: const Icon(Icons.push_pin_outlined, size: 18),
                    label: const Text('设为封面'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(sheetCtx, 'archive'),
                    icon: const Icon(Icons.archive_outlined, size: 18),
                    label: const Text('下架此实拍'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(CanteenTheme.radiusSm),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (action == null || !mounted) return;
    final provider = context.read<CanteenProvider>();
    final ok = action == 'cover'
        ? await provider.adminSetDishPhotoCover(photoId)
        : await provider.adminArchiveDishPhoto(photoId);
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(action == 'cover' ? '已设为封面' : '实拍已下架',
          context: context);
      await _load();
    } else {
      AppFeedback.error(provider.errorMessage ?? '操作失败', context: context);
    }
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) =>
      AppPageBackground(builder: _buildPageWithBackground);

  Widget _buildPageWithBackground(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAdmin = context.watch<AuthProvider>().user?.isAdmin == true ||
        context.watch<AuthProvider>().user?.isSuperAdmin == true;
    final hasData = _data != null;

    return Scaffold(
      backgroundColor:
          AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          _dishName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor:
            AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
        surfaceTintColor: Colors.transparent,
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
        actions: [
          if (hasData)
            IconButton(
              tooltip: '分享菜品',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: _share,
            ),
          if (isAdmin && hasData)
            PopupMenuButton<_AdminDishMenu>(
              tooltip: '管理这道菜',
              onSelected: _onAdminMenu,
              itemBuilder: (_) => const [
                PopupMenuItem(value: _AdminDishMenu.rename, child: Text('改名')),
                PopupMenuItem(value: _AdminDishMenu.hide, child: Text('隐藏')),
                PopupMenuItem(
                    value: _AdminDishMenu.merge, child: Text('合并到其他菜品')),
              ],
            ),
        ],
      ),
      bottomNavigationBar: hasData ? _buildBottomBar(isDark) : null,
      body: _isLoading
          ? const _DishDetailSkeleton()
          : !hasData
              ? CanteenEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: '菜品加载失败',
                  subtitle: _loadError,
                  actionLabel: '重新加载',
                  onAction: _load,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: dishPagePadding(context, top: 8, bottom: 32),
                    children: [
                      if (_photoImages.isNotEmpty) ...[
                        _buildPhotoSection(isDark, isAdmin),
                        const SizedBox(height: 14),
                      ],
                      _buildSummaryCard(isDark),
                      const SizedBox(height: 12),
                      _buildReviewPreview(isDark),
                      const SizedBox(height: 12),
                      _buildContributeHint(isDark),
                    ],
                  ),
                ),
    );
  }

  /// 菜品页统一的内容卡片：与首页评价卡、排行卡同一套底色、描边和圆角。
  Widget _card(bool isDark, {required Widget child, EdgeInsets? padding}) {
    return AppCardSurface(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: child,
    );
  }

  Widget _buildSummaryCard(bool isDark) {
    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.storefront_rounded,
                size: 15,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  widget.canteenName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ),
            ],
          ),
          if (_isOffline)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: CanteenTheme.surfaceMutedBg(isDark),
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                ),
                child: Text(
                  '所属商家已下架，历史菜品与实拍仅供参考',
                  style: TextStyle(
                    fontSize: 11,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '$_mentionCount 人评价中提到 · $_photoTotal 张同学真实实拍',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: CanteenTheme.borderColor(isDark),
            ),
          ),
          _buildScores(isDark),
        ],
      ),
    );
  }

  Widget _buildScores(bool isDark) {
    if (_ratedCount <= 0) {
      return Row(
        children: [
          Icon(
            Icons.star_outline_rounded,
            size: 18,
            color: CanteenTheme.textTertiaryColor(isDark),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '还没有同学给这道菜打分，写评价时可以顺手打个分',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ),
        ],
      );
    }
    final accent = CanteenTheme.accentColor(isDark);
    // 标签列宽跟随字号放大，大字号下“性价比”也不会被折成两行。
    final labelWidth =
        44 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8);
    Widget bar(String label, double value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: (value / 5).clamp(0.0, 1.0),
                    minHeight: 8,
                    color: accent,
                    backgroundColor: CanteenTheme.surfaceMutedBg(isDark),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 28,
                child: Text(
                  value.toStringAsFixed(1),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
              ),
            ],
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          label:
              '菜品综合分 ${_score('average').toStringAsFixed(1)}，$_ratedCount 人打分',
          excludeSemantics: true,
          child: Container(
            width: 84,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: CanteenTheme.accentSoftColor(isDark),
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
            ),
            child: Column(
              children: [
                Text(
                  _score('average').toStringAsFixed(1),
                  style: TextStyle(
                    fontSize: 30,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    color: CanteenTheme.accentStrongColor(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 12, color: accent),
                    const SizedBox(width: 2),
                    Text(
                      '$_ratedCount 人打分',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            children: [
              bar('味道', _score('taste')),
              bar('性价比', _score('value')),
              bar('分量', _score('portion')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewPreview(bool isDark) {
    final currentUserId = context.read<AuthProvider>().user?.id;
    return _card(
      isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '大家怎么说',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              if (_reviewTotal > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '· $_reviewTotal',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (_reviewsFailed)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '评价加载失败',
                    style: TextStyle(
                      fontSize: 12,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _load,
                  style: TextButton.styleFrom(
                    foregroundColor: CanteenTheme.accentStrongColor(isDark),
                  ),
                  child: const Text('重试'),
                ),
              ],
            )
          else if (_reviews.isEmpty)
            Text(
              '还没有同学评价这道菜',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            )
          else ...[
            for (var i = 0; i < _reviews.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Divider(
                    height: 1,
                    thickness: 0.5,
                    color: CanteenTheme.borderColor(isDark),
                  ),
                ),
              DishReviewTile(
                review: _reviews[i],
                maxCommentLines: 3,
                canReport:
                    currentUserId != (_reviews[i]['user_id'] as num?)?.toInt(),
              ),
            ],
            if (_reviewTotal > _reviews.length) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: _openAllReviews,
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '查看全部 $_reviewTotal 条评价',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: CanteenTheme.accentStrongColor(isDark),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: CanteenTheme.accentStrongColor(isDark),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 最新实拍放在页首：菜品页首先是“长什么样”。
  Widget _buildPhotoSection(bool isDark, bool isAdmin) {
    final shown = _photoImages.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DishPhotoMosaic(
          imageUrls: _photoImages,
          offline: _isOffline,
          onLongPress: isAdmin ? _handleAdminManagePhoto : null,
          onImageError: (imageUrl) {
            if (_failedPhotoImages.contains(imageUrl)) return;
            setState(() => _failedPhotoImages.add(imageUrl));
          },
        ),
        if (_photoTotal > shown || isAdmin)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
            child: Row(
              children: [
                if (_photoTotal > shown)
                  Expanded(
                    child: Text(
                      '共 $_photoTotal 张实拍，展示最新 $shown 张',
                      style: TextStyle(
                        fontSize: 11,
                        color: CanteenTheme.textTertiaryColor(isDark),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (isAdmin)
                  Text(
                    '管理员提示：长按实拍图片可设为封面或下架',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.redAccent.withAlpha(217),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildContributeHint(bool isDark) {
    final shown = _photoImages.length;
    return AppCardSurface(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
      ),
      child: Row(
        children: [
          Icon(
            _isOffline
                ? Icons.storefront_outlined
                : Icons.photo_camera_outlined,
            size: 18,
            color: CanteenTheme.textSecondaryColor(isDark),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _isOffline
                  ? '所属商家已下架，暂不能新增菜品实拍或评价'
                  : shown == 0
                      ? '还没有实拍。评价「$_dishName」时上传照片，就会展示在这里。'
                      : '吃过了？评价时上传新照片，会替换掉较旧的实拍。',
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(bool isDark) {
    if (_isOffline) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: dishPagePadding(context, top: 8, bottom: 12),
        child: FilledButton.icon(
          onPressed: _openReviewEditor,
          icon: const Icon(Icons.rate_review_outlined, size: 18),
          label: const Text('评价这道菜'),
          style: FilledButton.styleFrom(
            backgroundColor: CanteenTheme.accentColor(isDark),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜品详情首屏骨架：与真实布局同构（摘要卡 + 评价 + 实拍大图）。
class _DishDetailSkeleton extends StatelessWidget {
  const _DishDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = CanteenTheme.surfaceMutedBg(isDark);
    Widget block(double? width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: muted,
            borderRadius: BorderRadius.circular(8),
          ),
        );
    return Semantics(
      label: '正在加载菜品',
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          block(90, 12),
          const SizedBox(height: 10),
          block(220, 16),
          const SizedBox(height: 16),
          Row(
            children: [
              block(56, 48),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    block(null, 8),
                    const SizedBox(height: 8),
                    block(null, 8),
                    const SizedBox(height: 8),
                    block(null, 8),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          block(80, 14),
          const SizedBox(height: 10),
          block(null, 12),
          const SizedBox(height: 8),
          block(260, 12),
          const SizedBox(height: 24),
          AspectRatio(aspectRatio: 4 / 3, child: block(null, 0)),
        ],
      ),
    );
  }
}
