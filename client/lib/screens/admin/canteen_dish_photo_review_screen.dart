import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../providers/canteen_provider.dart';
import '../../screens/image_viewer_screen.dart';
import '../../widgets/rating_detail/ranking_tokens.dart';

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
    final items =
        await context.read<CanteenProvider>().adminListPendingDishPhotos();
    if (mounted) {
      setState(() {
        if (items == null) {
          // 请求失败：不得展示"暂无待审核"假空态。
          _loadFailed = true;
          _items = [];
        } else {
          _items = items;
        }
        _isLoading = false;
      });
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
    final success =
        await context.read<CanteenProvider>().adminRejectDishPhoto(photoId, reason);
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.canteenAccent(isDark);

    return Scaffold(
      backgroundColor: RankingTokens.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '菜品实拍审核',
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
    if (_items.isEmpty) {
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
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return _ReviewCard(
          item: item,
          isDark: isDark,
          accent: accent,
          onApprove: () => _approve(item),
          onReject: () => _reject(item),
        );
      },
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

  const _ReviewCard({
    required this.item,
    required this.isDark,
    required this.accent,
    required this.onApprove,
    required this.onReject,
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
                  ? CachedNetworkImage(
                      imageUrl: ApiConstants.fullUrl(image),
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
