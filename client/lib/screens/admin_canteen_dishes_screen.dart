import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen_dish.dart';
import '../providers/canteen_provider.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/canteen/admin_dish_actions.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';

/// 管理员菜品管理：改名、隐藏/恢复、合并重复菜品。
///
/// 同学写评价时可以直接输入菜名生成新菜，重复菜（“番茄炒蛋”/“西红柿炒鸡蛋”）
/// 只能靠这里人工合并；合并后旧名会作为别名继续指向目标菜。
class AdminCanteenDishesScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;

  const AdminCanteenDishesScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
  });

  @override
  State<AdminCanteenDishesScreen> createState() =>
      _AdminCanteenDishesScreenState();
}

enum _DishAction { rename, toggleVisibility, merge }

class _AdminCanteenDishesScreenState extends State<AdminCanteenDishesScreen> {
  List<AdminCanteenDish>? _dishes;
  bool _loading = true;
  String? _error;
  String _query = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    final provider = context.read<CanteenProvider>();
    final dishes = await provider.adminListDishes(widget.canteenId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      if (dishes != null) {
        _dishes = dishes;
      } else {
        _error = provider.errorMessage ?? '菜品列表加载失败，请重试';
      }
    });
  }

  Future<void> _run(_DishAction action, AdminCanteenDish dish) async {
    final Future<bool> pending = switch (action) {
      _DishAction.rename => showAdminRenameDishDialog(
          context,
          dishId: dish.id,
          currentName: dish.name,
        ),
      _DishAction.toggleVisibility => showAdminToggleDishVisibilityDialog(
          context,
          dishId: dish.id,
          dishName: dish.name,
          currentlyHidden: dish.isHidden,
        ),
      _DishAction.merge => showAdminMergeDishFlow(
          context,
          canteenId: widget.canteenId,
          sourceDishId: dish.id,
          sourceDishName: dish.name,
          candidates: _dishes,
        ),
    };
    if (await pending && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
      appBar: AppBar(
        title: Text('菜品管理 · ${widget.canteenName}'),
        backgroundColor:
            AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              onChanged: (value) => setState(() => _query = value.trim()),
              decoration: InputDecoration(
                hintText: '搜索菜名',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: true,
                filled: true,
                fillColor: CanteenTheme.surfaceMutedBg(isDark),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    final dishes = _dishes;
    if (_loading && dishes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (dishes == null) {
      return CanteenEmptyState(
        title: '加载失败',
        subtitle: _error,
        actionLabel: '重新加载',
        onAction: _load,
      );
    }
    final query = _query.toLowerCase();
    final visible = dishes
        .where(
            (dish) => query.isEmpty || dish.name.toLowerCase().contains(query))
        .toList(growable: false);
    if (visible.isEmpty) {
      return CanteenEmptyState(
        icon: Icons.restaurant_menu_rounded,
        title: dishes.isEmpty ? '这家店还没有菜品' : '没有找到「$_query」',
        subtitle: dishes.isEmpty ? '同学在评价里关联菜品后会出现在这里' : null,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, index) => _buildDishRow(isDark, visible[index]),
      ),
    );
  }

  Widget _buildDishRow(bool isDark, AdminCanteenDish dish) {
    return AppCardSurface(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        dish.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: dish.isHidden
                              ? CanteenTheme.textSecondaryColor(isDark)
                              : CanteenTheme.textPrimaryColor(isDark),
                        ),
                      ),
                    ),
                    if (dish.isHidden) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '已隐藏',
                          style: TextStyle(
                            fontSize: 11,
                            color: CanteenTheme.textSecondaryColor(isDark),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${dish.photoCount} 张实拍 · ${dish.mentionCount} 条评价提到',
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<_DishAction>(
            tooltip: '管理「${dish.name}」',
            onSelected: (action) => _run(action, dish),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _DishAction.rename,
                child: Text('改名'),
              ),
              PopupMenuItem(
                value: _DishAction.toggleVisibility,
                child: Text(dish.isHidden ? '恢复上架' : '隐藏'),
              ),
              const PopupMenuItem(
                value: _DishAction.merge,
                child: Text('合并到其他菜品'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
