import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/api_constants.dart';
import '../../models/canteen_dish.dart';
import '../../providers/canteen_provider.dart';
import '../../screens/canteen_dish_detail_screen.dart';
import '../../screens/image_viewer_screen.dart';
import 'canteen_empty_state.dart';
import 'canteen_theme.dart';
import 'canteen_status_image.dart';

/// 商家详情页菜品图鉴区。
/// 图片作为主体（148x104 圆角 14），卡片本身不描边；空态提供补充说明。
///
/// 职责分离：
/// - [onViewAll]：「查看全部」→ 菜品列表页
/// - [onStatsChanged]：图鉴加载后回传真实菜品/实拍统计，供详情头刷新
/// - [onStatsDetailedChanged]：额外回传“有实拍的菜品数”，与图片总数分开统计
class DishGallerySection extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  final VoidCallback? onViewAll;
  final void Function(int dishCount, int dishPhotoCount)? onStatsChanged;
  final void Function(
          int dishCount, int dishWithPhotoCount, int dishPhotoCount)?
      onStatsDetailedChanged;
  final List<CanteenDish>? initialDishes;
  final bool initialDishesLoadFailed;
  final String? initialDishesErrorMessage;

  const DishGallerySection({
    super.key,
    required this.canteenId,
    required this.canteenName,
    this.onViewAll,
    this.onStatsChanged,
    this.onStatsDetailedChanged,
    this.initialDishes,
    this.initialDishesLoadFailed = false,
    this.initialDishesErrorMessage,
  });

  @override
  State<DishGallerySection> createState() => _DishGallerySectionState();
}

class _DishGallerySectionState extends State<DishGallerySection> {
  List<CanteenDish> _dishes = [];
  bool _isLoading = true;
  bool _loadFailed = false;
  String? _errorSubtitle;
  IconData _errorIcon = Icons.cloud_off_rounded;
  final Set<String> _failedImageUrls = <String>{};

  List<CanteenDish> get _visibleDishes => _dishes
      .where((dish) =>
          dish.hasDisplayImage && !_failedImageUrls.contains(dish.coverImage))
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    if (widget.initialDishes != null || widget.initialDishesLoadFailed) {
      _dishes = widget.initialDishes ?? [];
      _isLoading = false;
      _loadFailed = widget.initialDishesLoadFailed;
      _errorSubtitle = widget.initialDishesErrorMessage;
      if (!_loadFailed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _notifyStats(_dishes);
        });
      }
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final dishes =
        await context.read<CanteenProvider>().loadDishes(widget.canteenId);
    if (!mounted) return;
    if (dishes == null) {
      // 请求失败：不刷新父级统计（保留入口快照），显示重试而非伪装空态
      final errorMsg =
          context.read<CanteenProvider>().dishesErrorMessage ?? '请稍后重试';
      setState(() {
        _isLoading = false;
        _loadFailed = true;
        _errorSubtitle = errorMsg;
        _errorIcon = errorMsg.contains('网络')
            ? Icons.wifi_off_rounded
            : Icons.cloud_off_rounded;
      });
      return;
    }
    setState(() {
      _dishes = dishes;
      _isLoading = false;
      _loadFailed = false;
    });
    _notifyStats(dishes);
  }

  void _notifyStats(List<CanteenDish> dishes) {
    // 聚合评价图片不是一道可评分菜品；菜品数/有实拍菜品数只统计真实菜品，
    // 但图片总数包含评价实拍，保证详情头部不会漏报用户贡献的图片。
    final realDishes = dishes.where((dish) => !dish.isReviewGallery).toList();
    widget.onStatsChanged?.call(
      realDishes.length,
      dishes.fold(0, (sum, d) => sum + d.photoCount),
    );
    widget.onStatsDetailedChanged?.call(
      realDishes.length,
      realDishes.where((dish) => dish.photoCount > 0).length,
      dishes.fold(0, (sum, d) => sum + d.photoCount),
    );
  }

  void _openDish(CanteenDish dish) {
    if (dish.isReviewGallery) {
      final images =
          dish.photoImages.isNotEmpty ? dish.photoImages : [dish.coverImage];
      final urls = images
          .where((image) => image.trim().isNotEmpty)
          .map(ApiConstants.fullUrl)
          .toList(growable: false);
      if (urls.isEmpty) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(imageUrls: urls),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CanteenDishDetailScreen(
          canteenId: widget.canteenId,
          dishId: dish.id,
          dishName: dish.name,
          canteenName: widget.canteenName,
        ),
      ),
    ).then((_) => _load());
  }

  void _hideFailedImage(String imageUrl) {
    if (_failedImageUrls.contains(imageUrl)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _failedImageUrls.contains(imageUrl)) return;
      setState(() => _failedImageUrls.add(imageUrl));
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visibleDishes = _visibleDishes;

    // 图鉴是图片驱动模块。数据成功但没有可展示实拍时，整个模块收起，
    // 不用餐具占位图制造“这里本应有图片”的错误预期。
    if (!_isLoading && !_loadFailed && visibleDishes.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '商家菜品',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: widget.onViewAll,
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Text(
                    '查看全部 →',
                    style: TextStyle(
                      fontSize: 13,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isLoading)
            _buildSkeleton(isDark)
          else if (_loadFailed)
            CanteenEmptyState(
              minHeight: 96,
              icon: _errorIcon,
              title: '菜品加载失败',
              subtitle: _errorSubtitle ?? '请稍后重试',
              actionLabel: '点击重试',
              onAction: _load,
            )
          else
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: visibleDishes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final dish = visibleDishes[index];
                  return _DishCard(
                    dish: dish,
                    isDark: isDark,
                    onTap: () => _openDish(dish),
                    onImageError: () => _hideFailedImage(dish.coverImage),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSkeleton(bool isDark) {
    final muted = CanteenTheme.surfaceMutedBg(isDark);
    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 3,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, __) => Container(
          width: 148,
          height: 130,
          decoration: BoxDecoration(
            color: muted,
            borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
          ),
        ),
      ),
    );
  }

}

class _DishCard extends StatelessWidget {
  final CanteenDish dish;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onImageError;

  const _DishCard({
    required this.dish,
    required this.isDark,
    required this.onTap,
    required this.onImageError,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 148,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
              child: SizedBox(
                width: 148,
                height: 104,
                child: dish.coverImage.isNotEmpty
                    ? CanteenStatusImage(
                        imageUrl: ApiConstants.fullUrl(dish.coverImage),
                        variant: 'thumb',
                        offline: dish.isCanteenOffline,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) {
                          onImageError();
                          return const SizedBox.shrink();
                        },
                        placeholder: (_, __) => _placeholder(),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              dish.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: CanteenTheme.textPrimaryColor(isDark),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${dish.photoCount} 张实拍',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: CanteenTheme.accentColor(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_rounded,
        size: 26,
        color: CanteenTheme.textTertiaryColor(isDark),
      ),
    );
  }
}
