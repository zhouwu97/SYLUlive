import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/dish_photo_mosaic.dart';
import '../widgets/image_upload_widget.dart';

/// 菜品详情页：实拍图库（1~3 张）+ 上传入口。无星级。
class CanteenDishDetailScreen extends StatefulWidget {
  final int canteenId;
  final int dishId;
  final String dishName;
  final String canteenName;

  const CanteenDishDetailScreen({
    super.key,
    required this.canteenId,
    required this.dishId,
    required this.dishName,
    required this.canteenName,
  });

  @override
  State<CanteenDishDetailScreen> createState() =>
      _CanteenDishDetailScreenState();
}

class _CanteenDishDetailScreenState extends State<CanteenDishDetailScreen> {
  Map<String, dynamic>? _data;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final data = await context
        .read<CanteenProvider>()
        .loadDishDetail(widget.canteenId, widget.dishId);
    if (mounted) {
      setState(() {
        _data = data;
        _isLoading = false;
      });
    }
  }

  List<String> get _photoImages {
    final photos = (_data?['photos'] as List?)?.cast<Map<String, dynamic>>();
    if (photos == null) return [];
    return photos
        .map((p) => p['image']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  int get _photoCount => _data?['photo_count'] ?? _photoImages.length;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);

    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          widget.dishName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
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
          : _data == null
              ? Center(
                  child: Text(
                    '加载失败',
                    style: TextStyle(
                        color: CanteenTheme.textSecondaryColor(isDark)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    Text(
                      widget.canteenName,
                      style: TextStyle(
                        fontSize: 13,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_photoCount 张同学真实实拍',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: CanteenTheme.textPrimaryColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DishPhotoMosaic(imageUrls: _photoImages),
                    const SizedBox(height: 16),
                    if (_photoCount >= 3)
                      _buildGalleryFull(isDark, accent)
                    else
                      _buildUploadEntry(isDark, accent),
                  ],
                ),
    );
  }

  Widget _buildGalleryFull(bool isDark, Color accent) {
    // 无白色卡片：内容直接铺在页面背景上
    return Row(
      children: [
        Icon(Icons.check_circle_rounded, color: accent, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '实拍图库 $_photoCount / 3',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '实拍资料已完善',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUploadEntry(bool isDark, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '实拍图库 $_photoCount / 3',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: CanteenTheme.textPrimaryColor(isDark),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () async {
            final success = await showDishPhotoUploadSheet(
              context,
              canteenId: widget.canteenId,
              dishId: widget.dishId,
              dishName: widget.dishName,
              provider: context.read<CanteenProvider>(),
            );
            if (success == true && mounted) {
              await _load();
            }
          },
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
            ),
          ),
          icon: const Icon(Icons.add_a_photo_rounded, size: 20),
          label: const Text('上传菜品实拍'),
        ),
      ],
    );
  }
}

/// 在食堂详情页复用的上传 Sheet 入口。
/// 返回 true 表示提交成功。
Future<bool?> showDishPhotoUploadSheet(
  BuildContext context, {
  required int canteenId,
  int? dishId,
  String? dishName,
  required CanteenProvider provider,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _DishPhotoUploadSheet(
      canteenId: canteenId,
      dishId: dishId,
      dishName: dishName,
      provider: provider,
    ),
  );
}

// ── Upload sheet ────────────────────────────────────────────────────

class _DishPhotoUploadSheet extends StatefulWidget {
  final int canteenId;
  final int? dishId;
  final String? dishName;
  final CanteenProvider provider;

  const _DishPhotoUploadSheet({
    required this.canteenId,
    this.dishId,
    this.dishName,
    required this.provider,
  });

  @override
  State<_DishPhotoUploadSheet> createState() => _DishPhotoUploadSheetState();
}

class _DishPhotoUploadSheetState extends State<_DishPhotoUploadSheet> {
  int? _fileId;
  bool _submitting = false;

  bool get _canSubmit => _fileId != null && widget.dishId != null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: CanteenTheme.surfaceBg(isDark),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CanteenTheme.borderColor(isDark),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '上传菜品实拍',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.dishName ?? '这道菜',
                style: TextStyle(
                  fontSize: 13,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '请上传能清楚看到菜品主体的真实照片。图片通过管理员审核后公开展示。',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textTertiaryColor(isDark),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              // 复用现有上传组件（单图）
              _fileId == null
                  ? ImageUploadWidget(
                      maxImages: 1,
                      largeCard: true,
                      emptyTitle: '添加实拍',
                      emptySubtitle: '建议上传清晰菜品照片',
                      onImagesUploaded: (images) {
                        if (images.isNotEmpty) {
                          setState(() => _fileId = images.first.fileId);
                        }
                      },
                    )
                  : _buildSelectedImage(isDark, accent),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _submitting || !_canSubmit ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                  ),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('提交审核'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedImage(bool isDark, Color accent) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 40,
            color: accent,
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_rounded, size: 32),
                const SizedBox(height: 6),
                Text(
                  '已选择 1 张实拍',
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: InkWell(
              onTap: () => setState(() => _fileId = null),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final message = await widget.provider.submitDishPhoto(
      widget.canteenId,
      dishId: widget.dishId,
      dishName: widget.dishName,
      fileId: _fileId!,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    final isFull = widget.provider.errorCode == 'dish_gallery_full';
    if (message != null) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } else if (isFull) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该菜品已有 3 张公开实拍，暂不需要补充')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提交失败，请稍后重试')),
      );
    }
  }
}
