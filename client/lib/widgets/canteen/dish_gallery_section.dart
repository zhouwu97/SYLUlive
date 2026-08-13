import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../models/canteen_dish.dart';
import '../../providers/canteen_provider.dart';
import '../../screens/canteen_dish_detail_screen.dart';
import 'canteen_empty_state.dart';
import 'canteen_theme.dart';

/// 食堂详情页「大家都在吃」菜品图鉴区。
/// 图片作为主体（148x104 圆角 14），卡片本身不描边；空态提供上传 CTA。
///
/// 职责分离：
/// - [onViewAll]：「查看全部」→ 菜品列表页
/// - [onUpload]：空态「上传菜品实拍」→ 直接打开上传 Sheet（dish_name 模式）
/// - [onStatsChanged]：图鉴加载后回传真实菜品/实拍统计，供详情头刷新
class DishGallerySection extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  final VoidCallback? onViewAll;
  final VoidCallback? onUpload;
  final void Function(int dishCount, int dishPhotoCount)? onStatsChanged;

  const DishGallerySection({
    super.key,
    required this.canteenId,
    required this.canteenName,
    this.onViewAll,
    this.onUpload,
    this.onStatsChanged,
  });

  @override
  State<DishGallerySection> createState() => _DishGallerySectionState();
}

class _DishGallerySectionState extends State<DishGallerySection> {
  List<CanteenDish> _dishes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dishes = await context
        .read<CanteenProvider>()
        .loadDishes(widget.canteenId);
    if (!mounted) return;
    setState(() {
      _dishes = dishes;
      _isLoading = false;
    });
    // 回传真实统计：/dishes 只返回有 approved 实拍的公开菜，photoCount 即实拍数
    widget.onStatsChanged?.call(
      dishes.length,
      dishes.fold(0, (sum, d) => sum + d.photoCount),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '大家都在吃',
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
          else if (_dishes.isEmpty)
            _buildEmpty(isDark)
          else
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _dishes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final dish = _dishes[index];
                  return _DishCard(
                    dish: dish,
                    isDark: isDark,
                    onTap: () {
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
                    },
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

  Widget _buildEmpty(bool isDark) {
    return CanteenEmptyState(
      minHeight: 96,
      icon: Icons.photo_camera_outlined,
      title: '还没有同学上传菜品实拍',
      subtitle: '来补充第一张真实照片吧',
      actionLabel: '上传菜品实拍',
      onAction: widget.onUpload,
    );
  }
}

class _DishCard extends StatelessWidget {
  final CanteenDish dish;
  final bool isDark;
  final VoidCallback onTap;

  const _DishCard({
    required this.dish,
    required this.isDark,
    required this.onTap,
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
                    ? CachedNetworkImage(
                        imageUrl: ApiConstants.fullUrl(dish.coverImage),
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _placeholder(),
                        placeholder: (_, __) => _placeholder(),
                      )
                    : _placeholder(),
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
