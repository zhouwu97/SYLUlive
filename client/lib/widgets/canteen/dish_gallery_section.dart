import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../models/canteen_dish.dart';
import '../../providers/canteen_provider.dart';
import '../../screens/canteen_dish_detail_screen.dart';
import '../rating_detail/ranking_tokens.dart';

/// 食堂详情页「大家都在吃」菜品图鉴区。
class DishGallerySection extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  final VoidCallback? onUpload;

  const DishGallerySection({
    super.key,
    required this.canteenId,
    required this.canteenName,
    this.onUpload,
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
    if (mounted) {
      setState(() {
        _dishes = dishes;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.canteenAccent(isDark);

    if (_isLoading) {
      return const SizedBox(height: 40, child: Center(child: SizedBox(
        width: 20, height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      )));
    }
    if (_dishes.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: widget.onUpload ??
                    () {
                      // 全部 → 菜品列表页（由调用方注入）
                    },
                child: Text(
                  '全部 >',
                  style: TextStyle(
                    fontSize: 13,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
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
                  accent: accent,
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
}

class _DishCard extends StatelessWidget {
  final CanteenDish dish;
  final bool isDark;
  final Color accent;
  final VoidCallback onTap;

  const _DishCard({
    required this.dish,
    required this.isDark,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 116,
        decoration: RankingTokens.cardDecoration(isDark),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 88,
              width: double.infinity,
              child: dish.coverImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: ApiConstants.fullUrl(dish.coverImage),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _placeholder(),
                      placeholder: (_, __) => _placeholder(),
                    )
                  : _placeholder(),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dish.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: RankingTokens.titleColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${dish.photoCount} 张实拍',
                    style: TextStyle(
                      fontSize: 11,
                      color: accent,
                      fontWeight: FontWeight.w600,
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

  Widget _placeholder() {
    return Container(
      color: RankingTokens.canteenAccentSoft(isDark),
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_rounded,
        size: 26,
        color: RankingTokens.canteenAccent(isDark),
      ),
    );
  }
}
