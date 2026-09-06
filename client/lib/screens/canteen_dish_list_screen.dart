import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_constants.dart';
import '../models/canteen_dish.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/canteen_status_image.dart';
import 'canteen_dish_detail_screen.dart';

/// 商家菜品列表页。
class CanteenDishListScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  final bool offline;

  const CanteenDishListScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
    this.offline = false,
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

  void _openDish(CanteenDish dish) {
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

  /// 实拍图库是图片驱动页面，0 实拍菜品不渲染占位卡；
  /// 无图菜品的收录与选择仍由评价编辑器使用完整列表承担。
  List<CanteenDish> get _visibleDishes =>
      _dishes.where((dish) => dish.hasDisplayImage).toList(growable: false);

  CanteenEmptyState _buildEmptyState() {
    if (widget.offline) {
      return const CanteenEmptyState(
        icon: Icons.restaurant_menu_rounded,
        title: '暂无收录菜品',
        subtitle: '所属商家已下架',
      );
    }
    if (_dishes.isEmpty) {
      return const CanteenEmptyState(
        icon: Icons.restaurant_menu_rounded,
        title: '暂无收录菜品',
        subtitle: '发表食堂评价时填写菜品名称即可自动收录',
      );
    }
    return const CanteenEmptyState(
      icon: Icons.photo_camera_back_rounded,
      title: '暂无菜品实拍',
      subtitle: '发表评价时关联菜品并上传实拍即可展示在这里',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '商家菜品',
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
              : _visibleDishes.isEmpty
                  ? _buildEmptyState()
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: _visibleDishes.length,
                      itemBuilder: (context, index) {
                        final dish = _visibleDishes[index];
                        return _GridDishCard(
                          dish: dish,
                          isDark: isDark,
                          onTap: () => _openDish(dish),
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
                    ? CanteenStatusImage(
                        imageUrl: ApiConstants.fullUrl(dish.coverImage),
                        variant: 'thumb',
                        offline: dish.isCanteenOffline,
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
