import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/canteen_dish.dart';
import '../../providers/canteen_discovery_provider.dart';
import '../../providers/canteen_provider.dart';
import '../app_dialog.dart';
import 'canteen_theme.dart';

/// 管理员菜品治理动作（改名 / 隐藏或恢复 / 合并）的共享弹窗。
///
/// 菜品管理页和菜品详情页共用同一套确认文案，避免两处入口说法不一致。
/// 每个函数返回 true 表示服务端已经成功修改，调用方据此刷新列表或退出详情。

void _afterAdminDishChange(BuildContext context, bool ok, String successText) {
  if (!context.mounted) return;
  if (ok) {
    // 改名、隐藏、合并都会影响首页热门菜品和排行里的菜品数。
    context.read<CanteenDiscoveryProvider>().invalidateRanking();
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(ok
        ? successText
        : context.read<CanteenProvider>().errorMessage ?? '操作失败，请稍后重试'),
  ));
}

Future<bool> showAdminRenameDishDialog(
  BuildContext context, {
  required int dishId,
  required String currentName,
}) async {
  final controller = TextEditingController(text: currentName);
  final name = await showAppDialog<String>(
    context: context,
    builder: (dialogContext) => AppAlertDialog(
      title: const Text('修改菜名'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(hintText: '请输入新的菜名'),
          ),
          const Text(
            '旧菜名会保留为别名，同学再输入旧名时会自动指向这道菜。',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.isEmpty || name == currentName || !context.mounted) {
    return false;
  }
  final ok =
      await context.read<CanteenProvider>().adminUpdateDish(dishId, name: name);
  if (context.mounted) _afterAdminDishChange(context, ok, '菜名已修改');
  return ok;
}

Future<bool> showAdminToggleDishVisibilityDialog(
  BuildContext context, {
  required int dishId,
  required String dishName,
  required bool currentlyHidden,
}) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AppAlertDialog(
      title: Text(currentlyHidden ? '恢复「$dishName」' : '隐藏「$dishName」'),
      content: Text(currentlyHidden
          ? '恢复后这道菜会重新出现在菜品列表、搜索和评价选择里。'
          : '隐藏后这道菜不再出现在菜品列表、搜索和评价选择里，已有评价保留，之后可以恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(currentlyHidden ? '恢复' : '隐藏'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final ok = await context.read<CanteenProvider>().adminUpdateDish(
        dishId,
        status: currentlyHidden ? 'active' : 'hidden',
      );
  if (context.mounted) {
    _afterAdminDishChange(context, ok, currentlyHidden ? '已恢复' : '已隐藏');
  }
  return ok;
}

/// 选择合并目标并二次确认。[candidates] 为空时会先向服务端拉取该商家的菜品。
Future<bool> showAdminMergeDishFlow(
  BuildContext context, {
  required int canteenId,
  required int sourceDishId,
  required String sourceDishName,
  List<AdminCanteenDish>? candidates,
}) async {
  final provider = context.read<CanteenProvider>();
  final all = candidates ?? await provider.adminListDishes(canteenId);
  if (!context.mounted) return false;
  if (all == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(provider.errorMessage ?? '菜品列表加载失败，请重试'),
    ));
    return false;
  }
  final targets = all
      .where((dish) => dish.id != sourceDishId && !dish.isHidden)
      .toList(growable: false);
  if (targets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这家店没有其他上架菜品可以合并')),
    );
    return false;
  }
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final target = await showModalBottomSheet<AdminCanteenDish>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: CanteenTheme.surfaceBg(isDark),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) =>
        _MergeTargetSheet(sourceName: sourceDishName, targets: targets),
  );
  if (target == null || !context.mounted) return false;
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AppAlertDialog(
      title: const Text('确认合并'),
      content: Text(
        '把「$sourceDishName」合并到「${target.name}」？\n\n'
        '它的评价关联、菜品评分和实拍都会转到「${target.name}」，'
        '以后输入「$sourceDishName」也会自动指向「${target.name}」。合并后不能撤销。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('确认合并'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final ok = await provider.adminMergeDish(sourceDishId, target.id);
  if (context.mounted) {
    _afterAdminDishChange(context, ok, '已合并到「${target.name}」');
  }
  return ok;
}

class _MergeTargetSheet extends StatefulWidget {
  final String sourceName;
  final List<AdminCanteenDish> targets;

  const _MergeTargetSheet({required this.sourceName, required this.targets});

  @override
  State<_MergeTargetSheet> createState() => _MergeTargetSheetState();
}

class _MergeTargetSheetState extends State<_MergeTargetSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final visible = widget.targets
        .where(
            (dish) => query.isEmpty || dish.name.toLowerCase().contains(query))
        .toList(growable: false);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '把「${widget.sourceName}」合并到…',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: const InputDecoration(
                  hintText: '搜索目标菜品',
                  prefixIcon: Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
            ),
            Flexible(
              child: visible.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('没有匹配的菜品')),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final dish = visible[index];
                        return ListTile(
                          title: Text(dish.name),
                          subtitle: Text(
                              '${dish.photoCount} 张实拍 · ${dish.mentionCount} 条评价提到'),
                          onTap: () => Navigator.pop(context, dish),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
