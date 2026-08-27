import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../providers/canteen_provider.dart';
import '../../screens/image_viewer_screen.dart';
import '../../widgets/rating_detail/ranking_tokens.dart';
import '../../widgets/canteen/canteen_status_image.dart';

/// 管理员菜品实拍审核页：待审核列表 + 通过/驳回。
class CanteenDishPhotoReviewScreen extends StatefulWidget {
  const CanteenDishPhotoReviewScreen({super.key});

  @override
  State<CanteenDishPhotoReviewScreen> createState() =>
      _CanteenDishPhotoReviewScreenState();
}

class _CanteenDishPhotoReviewScreenState
    extends State<CanteenDishPhotoReviewScreen> {
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _pendingDishes = [];
  bool _isLoading = true;
  bool _loadFailed = false;

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
    final provider = context.read<CanteenProvider>();
    final results = await Future.wait([
      provider.adminListPendingDishPhotos(),
      provider.adminListPendingDishes(),
    ]);
    final items = results[0];
    final dishes = results[1];
    if (mounted) {
      setState(() {
        if (items == null && dishes == null) {
          // 请求失败：不得展示"暂无待审核"假空态。
          _loadFailed = true;
          _items = [];
        } else {
          _items = items ?? const [];
          _pendingDishes = dishes ?? const [];
        }
        _isLoading = false;
      });
    }
  }

  Future<void> _approveDish(Map<String, dynamic> item) async {
    final dishId = (item['id'] as num?)?.toInt() ?? 0;
    final success =
        await context.read<CanteenProvider>().adminApproveDish(dishId);
    if (!mounted) return;
    if (success) {
      setState(
          () => _pendingDishes.removeWhere((dish) => dish['id'] == dishId));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('菜品已通过')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('通过菜品失败，请刷新后重试')));
    }
  }

  Future<void> _rejectDish(Map<String, dynamic> item) async {
    final dishId = (item['id'] as num?)?.toInt() ?? 0;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('驳回菜品原因'),
        children: const [
          _ReasonOption('unrelated', '与食堂菜品无关'),
          _ReasonOption('duplicate', '与已有菜品重复'),
          _ReasonOption('inappropriate', '不适宜内容'),
          _ReasonOption('other', '其他'),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    final success =
        await context.read<CanteenProvider>().adminRejectDish(dishId, reason);
    if (!mounted) return;
    if (success) {
      setState(
          () => _pendingDishes.removeWhere((dish) => dish['id'] == dishId));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('菜品已驳回')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('驳回菜品失败，请刷新后重试')));
    }
  }

  Future<void> _approve(Map<String, dynamic> item) async {
    final provider = context.read<CanteenProvider>();
    final photoId = (item['photo_id'] as num?)?.toInt() ?? 0;
    final message = await provider.adminApproveDishPhoto(photoId);
    if (!mounted) return;
    if (message != null) {
      setState(() => _items.removeWhere((i) => i['photo_id'] == photoId));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } else if (provider.errorCode == 'dish_gallery_full') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该菜品已有 3 张公开实拍，请先下架旧图片')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('操作失败，请稍后重试')),
      );
    }
  }

  Future<void> _reject(Map<String, dynamic> item) async {
    final photoId = (item['photo_id'] as num?)?.toInt() ?? 0;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('驳回原因'),
        children: const [
          _ReasonOption('unrelated', '与菜品不符'),
          _ReasonOption('blurry', '图片过于模糊'),
          _ReasonOption('duplicate', '重复图片'),
          _ReasonOption('privacy', '包含明显个人隐私'),
          _ReasonOption('advertisement', '广告 / 二维码'),
          _ReasonOption('inappropriate', '不适宜内容'),
          _ReasonOption('other', '其他'),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    final success = await context
        .read<CanteenProvider>()
        .adminRejectDishPhoto(photoId, reason);
    if (!mounted) return;
    if (success) {
      setState(() => _items.removeWhere((i) => i['photo_id'] == photoId));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已驳回')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('驳回失败，请稍后重试')),
      );
    }
  }

  Future<void> _merge(Map<String, dynamic> item) async {
    final sourceDishId = (item['dish_id'] as num?)?.toInt() ??
        (item['id'] as num?)?.toInt() ??
        0;
    final rawMatches = item['possible_matches'];
    if (sourceDishId == 0 || rawMatches is! List || rawMatches.isEmpty) return;
    final matches = rawMatches.whereType<Map>().toList();
    if (matches.isEmpty || !mounted) return;
    final target = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择合并目标'),
        children: matches.map((raw) {
          final candidate = Map<String, dynamic>.from(raw);
          final score =
              ((candidate['match_score'] as num?)?.toDouble() ?? 0) * 100;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, candidate),
            child: Row(
              children: [
                Expanded(child: Text(candidate['name']?.toString() ?? '未命名菜品')),
                Text('${score.toStringAsFixed(0)}%'),
              ],
            ),
          );
        }).toList(),
      ),
    );
    final targetDishId = (target?['dish_id'] as num?)?.toInt() ?? 0;
    if (targetDishId == 0 || !mounted) return;
    final success = await context
        .read<CanteenProvider>()
        .adminMergeDish(sourceDishId, targetDishId);
    if (!mounted) return;
    if (success) {
      setState(() {
        _items.removeWhere((i) => i['dish_id'] == sourceDishId);
        _pendingDishes.removeWhere((i) =>
            (i['id'] as num?)?.toInt() == sourceDishId ||
            (i['dish_id'] as num?)?.toInt() == sourceDishId);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已合并到目标菜品')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('合并失败，请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.canteenAccent(isDark);

    return Scaffold(
      backgroundColor: RankingTokens.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '菜品与实拍审核',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: RankingTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: RankingTokens.titleColor(isDark),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(isDark, accent),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color accent) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 48,
                  color: RankingTokens.subColor(isDark),
                ),
                const SizedBox(height: 12),
                Text(
                  '审核列表加载失败',
                  style: TextStyle(
                    fontSize: 14,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _load,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty && _pendingDishes.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 48,
                  color: RankingTokens.subColor(isDark),
                ),
                const SizedBox(height: 12),
                Text(
                  '暂无待审核实拍',
                  style: TextStyle(
                    fontSize: 14,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final total = _items.length + _pendingDishes.length;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: total,
      itemBuilder: (context, index) {
        if (index < _pendingDishes.length) {
          final dish = _pendingDishes[index];
          return _PendingDishCard(
            item: dish,
            isDark: isDark,
            accent: accent,
            onApprove: () => _approveDish(dish),
            onReject: () => _rejectDish(dish),
            onMerge: () => _merge(dish),
          );
        }
        final item = _items[index - _pendingDishes.length];
        return _ReviewCard(
          item: item,
          isDark: isDark,
          accent: accent,
          onApprove: () => _approve(item),
          onReject: () => _reject(item),
          onMerge: () => _merge(item),
        );
      },
    );
  }
}

class _PendingDishCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isDark;
  final Color accent;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onMerge;

  const _PendingDishCard({
    required this.item,
    required this.isDark,
    required this.accent,
    required this.onApprove,
    required this.onReject,
    required this.onMerge,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: RankingTokens.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restaurant_outlined, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item['name']?.toString() ?? '未命名菜品',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: RankingTokens.titleColor(isDark),
                  ),
                ),
              ),
              Text(
                '待收录',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${item['canteen_name'] ?? ''} · 待审核实拍 ${(item['pending_photo_count'] as num?)?.toInt() ?? 0} 张',
            style: TextStyle(
              fontSize: 13,
              color: RankingTokens.subColor(isDark),
            ),
          ),
          const SizedBox(height: 12),
          if (item['possible_matches'] is List &&
              (item['possible_matches'] as List).isNotEmpty) ...[
            OutlinedButton.icon(
              onPressed: onMerge,
              icon: const Icon(Icons.merge_type_rounded, size: 18),
              label: const Text('可能重复：选择合并目标'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: accent,
                side: BorderSide(color: accent.withValues(alpha: 0.45)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  child: const Text('驳回'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: onApprove,
                  style: FilledButton.styleFrom(backgroundColor: accent),
                  child: const Text('通过'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReasonOption extends StatelessWidget {
  final String value;
  final String label;

  const _ReasonOption(this.value, this.label);

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, value),
      child: Text(label),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isDark;
  final Color accent;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onMerge;

  const _ReviewCard({
    required this.item,
    required this.isDark,
    required this.accent,
    required this.onApprove,
    required this.onReject,
    required this.onMerge,
  });

  @override
  Widget build(BuildContext context) {
    final image = item['image']?.toString() ?? '';
    final dishName = item['dish_name']?.toString() ?? '';
    final canteenName = item['canteen_name']?.toString() ?? '';
    final uploader = item['uploader_name']?.toString() ?? '匿名';
    final approved = (item['approved_count'] as num?)?.toInt() ?? 0;
    final createdAt = item['created_at']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: RankingTokens.cardDecoration(isDark),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              if (image.isEmpty) return;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                    imageUrls: [ApiConstants.fullUrl(image)],
                    initialIndex: 0,
                  ),
                ),
              );
            },
            child: SizedBox(
              height: 200,
              width: double.infinity,
              child: image.isNotEmpty
                  ? CanteenStatusImage(
                      imageUrl: image,
                      variant: 'thumb',
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _placeholder(),
                      placeholder: (_, __) => _placeholder(),
                    )
                  : _placeholder(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dishName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: RankingTokens.titleColor(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  canteenName,
                  style: TextStyle(
                    fontSize: 13,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _chip('当前图库 $approved / 3', isDark, accent),
                    const SizedBox(width: 8),
                    _chip('投稿：$uploader', isDark, null),
                  ],
                ),
                const SizedBox(height: 6),
                if (createdAt.isNotEmpty)
                  Text(
                    createdAt,
                    style: TextStyle(
                      fontSize: 11,
                      color: RankingTokens.mutedColor(isDark),
                    ),
                  ),
                if (item['possible_matches'] is List &&
                    (item['possible_matches'] as List).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onMerge,
                    icon: const Icon(Icons.merge_type_rounded, size: 18),
                    label: const Text('可能重复：选择合并目标'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(40),
                      foregroundColor: accent,
                      side: BorderSide(color: accent.withValues(alpha: 0.45)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onReject,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          side: BorderSide(
                            color: RankingTokens.borderColor(isDark),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          '驳回',
                          style: TextStyle(
                            color: RankingTokens.subColor(isDark),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: onApprove,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('通过'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, bool isDark, Color? color) {
    final c = color ?? RankingTokens.subColor(isDark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: RankingTokens.canteenAccentSoft(isDark),
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 32,
        color: RankingTokens.canteenAccent(isDark),
      ),
    );
  }
}
