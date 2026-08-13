import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../config/api_constants.dart';
import '../models/canteen_dish.dart';
import '../providers/canteen_provider.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import 'canteen_dish_detail_screen.dart';

/// 食堂全部菜品列表页。
class CanteenDishListScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;

  const CanteenDishListScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
  });

  @override
  State<CanteenDishListScreen> createState() => _CanteenDishListScreenState();
}

class _CanteenDishListScreenState extends State<CanteenDishListScreen> {
  List<CanteenDish> _dishes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dishes =
        await context.read<CanteenProvider>().loadDishes(widget.canteenId);
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

    return Scaffold(
      backgroundColor: RankingTokens.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '全部菜品',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: RankingTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: RankingTokens.titleColor(isDark),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _dishes.isEmpty
              ? Center(
                  child: Text(
                    '暂无实拍菜品',
                    style: TextStyle(color: RankingTokens.subColor(isDark)),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: _dishes.length,
                  itemBuilder: (context, index) {
                    final dish = _dishes[index];
                    return _GridDishCard(
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
    );
  }
}

class _GridDishCard extends StatelessWidget {
  final CanteenDish dish;
  final bool isDark;
  final VoidCallback onTap;

  const _GridDishCard({
    required this.dish,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: RankingTokens.cardDecoration(isDark),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
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
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: RankingTokens.titleColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${dish.photoCount} 张实拍',
                    style: TextStyle(
                      fontSize: 12,
                      color: RankingTokens.subColor(isDark),
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
        size: 30,
        color: RankingTokens.canteenAccent(isDark),
      ),
    );
  }
}
