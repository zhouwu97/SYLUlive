import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../config/api_constants.dart';
import '../models/canteen_dish.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
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
  bool _loadFailed = false;
  String? _errorSubtitle;
  IconData _errorIcon = Icons.cloud_off_rounded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final dishes =
        await context.read<CanteenProvider>().loadDishes(widget.canteenId);
    if (mounted) {
      final errorMsg =
          context.read<CanteenProvider>().dishesErrorMessage ?? '请稍后重试';
      setState(() {
        _dishes = dishes ?? _dishes;
        _isLoading = false;
        _loadFailed = dishes == null;
        _errorSubtitle = errorMsg;
        _errorIcon = errorMsg.contains('网络')
            ? Icons.wifi_off_rounded
            : Icons.cloud_off_rounded;
      });
    }
  }

  /// 空列表 → 直接打开上传 Sheet（dish_name 模式），可输入新菜名投稿第一张实拍。
  Future<void> _openUploadSheet() async {
    final success = await showDishPhotoUploadSheet(
      context,
      canteenId: widget.canteenId,
      provider: context.read<CanteenProvider>(),
    );
    if (success == true && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '全部菜品',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: CanteenTheme.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? CanteenEmptyState(
                  icon: _errorIcon,
                  title: '菜品加载失败',
                  subtitle: _errorSubtitle ?? '请稍后重试',
                  actionLabel: '点击重试',
                  onAction: _load,
                )
              : _dishes.isEmpty
                  ? CanteenEmptyState(
                      icon: Icons.photo_camera_outlined,
                      title: '还没有实拍菜品',
                      subtitle: '上传第一道菜的第一张实拍吧',
                      actionLabel: '上传第一道菜实拍',
                      onAction: _openUploadSheet,
                    )
                  : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
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
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图片独立圆角，无白色卡片容器 / 边框 / 阴影
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
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
          ),
          const SizedBox(height: 8),
          Text(
            dish.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${dish.photoCount} 张实拍',
            style: TextStyle(
              fontSize: 12,
              color: CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_rounded,
        size: 30,
        color: CanteenTheme.textTertiaryColor(isDark),
      ),
    );
  }
}
