import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../config/api_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/rating_detail/rating_report_sheet.dart';
import '../widgets/canteen/dish_photo_mosaic.dart';
import '../widgets/image_upload_widget.dart';

/// 菜品详情页：菜品三维评价 + 实拍图库（1~3 张）+ 上传入口。
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
  List<Map<String, dynamic>> _reviews = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<CanteenProvider>();
    final data = await provider.loadDishDetail(widget.canteenId, widget.dishId);
    final reviews = await provider.loadDishReviews(widget.dishId);
    if (mounted) {
      setState(() {
        _data = data;
        _reviews = reviews ?? [];
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _photos {
    return (_data?['photos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  List<String> get _photoImages {
    return _photos
        .map((p) => p['image']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  int get _photoCount => _data?['photo_count'] ?? _photoImages.length;

  bool get _isOffline {
    final dish = _data?['dish'];
    if (dish is! Map) return false;
    return dish['canteen_operating_status']?.toString() == 'offline';
  }

  Future<void> _handleAdminManagePhoto(int index) async {
    final photos = _photos;
    if (index < 0 || index >= photos.length) return;
    final photo = photos[index];
    final photoId = (photo['id'] as num?)?.toInt();
    if (photoId == null) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final initialUploaderName =
        photo['uploader_name'] ?? photo['nickname'] ?? '同学';
    final initialCreatedAt = photo['created_at']?.toString() ?? '';

    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => FutureBuilder<Map<String, dynamic>?>(
        future:
            context.read<CanteenProvider>().adminGetDishPhotoDetail(photoId),
        builder: (ctx, snapshot) {
          final detail = snapshot.data;
          final uploaderName = detail?['uploader_name'] ?? initialUploaderName;
          final createdAt =
              detail?['created_at']?.toString() ?? initialCreatedAt;

          return Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: CanteenTheme.surfaceBg(isDark),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: CanteenTheme.borderColor(isDark),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '管理已发布实拍',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: CanteenTheme.textPrimaryColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '上传者：$uploaderName${createdAt.isNotEmpty ? ' · $createdAt' : ''}',
                    style: TextStyle(
                      fontSize: 13,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(sheetCtx, true),
                    icon: const Icon(Icons.archive_outlined, size: 18),
                    label: const Text('下架此实拍（释放名额）'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(CanteenTheme.radiusSm),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetCtx, false),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (confirm == true && mounted) {
      final provider = context.read<CanteenProvider>();
      final ok = await provider.adminArchiveDishPhoto(photoId);
      if (!mounted) return;
      if (ok) {
        AppFeedback.success('实拍已下架', context: context);
        await _load();
      } else {
        AppFeedback.error(provider.errorMessage ?? '下架失败', context: context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);
    final auth = context.watch<AuthProvider>();
    final isAdmin =
        auth.user?.isAdmin == true || auth.user?.isSuperAdmin == true;

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
                    if (_isOffline)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '所属商家已下架，历史菜品与实拍仅供参考',
                          style: TextStyle(
                            fontSize: 12,
                            color: CanteenTheme.textSecondaryColor(isDark),
                          ),
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
                    _buildRatingSummary(isDark, accent),
                    if (_reviews.isNotEmpty) _buildReviewList(isDark),
                    if (isAdmin && _photos.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Text(
                          '管理员提示：长按实拍图片可进行下架治理',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.redAccent.withAlpha(217),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    DishPhotoMosaic(
                      imageUrls: _photoImages,
                      offline: _isOffline,
                      onLongPress: isAdmin ? _handleAdminManagePhoto : null,
                    ),
                    const SizedBox(height: 16),
                    if (_photoCount >= 3)
                      _buildGalleryFull(isDark, accent)
                    else if (_isOffline)
                      _buildOfflineUploadNotice(isDark)
                    else
                      _buildUploadEntry(isDark, accent),
                  ],
                ),
    );
  }

  Widget _buildRatingSummary(bool isDark, Color accent) {
    // 旧服务端/旧测试没有 V2 菜品评分字段时不插入占位内容，保持图库首屏布局稳定。
    final hasV2Data = _data?.containsKey('average_score') == true ||
        _data?.containsKey('dimension_scores') == true ||
        _data?.containsKey('reviewer_count') == true;
    if (!hasV2Data) return const SizedBox.shrink();
    final average = (_data?['average_score'] as num?)?.toDouble() ?? 0;
    final count = (_data?['reviewer_count'] as num?)?.toInt() ?? 0;
    final raw = _data?['dimension_scores'];
    final scores =
        raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final dimensions = <({String key, String label})>[
      (key: 'taste', label: '味道'),
      (key: 'value', label: '性价比'),
      (key: 'portion', label: '分量'),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CanteenTheme.surfaceBg(isDark),
          borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
          border: Border.all(color: CanteenTheme.borderColor(isDark)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.star_rounded, size: 17, color: accent),
                const SizedBox(width: 4),
                Text(
                  average > 0 ? average.toStringAsFixed(1) : '暂无评分',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count 人评价 · 味道 / 性价比 / 分量',
                  style: TextStyle(
                    fontSize: 11,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ],
            ),
            if (scores.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: dimensions.map((item) {
                  final score = scores[item.key] is num
                      ? (scores[item.key] as num).toDouble()
                      : 0.0;
                  return Text(
                    '${item.label} ${score.toStringAsFixed(1)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReviewList(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '菜品评价',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          const SizedBox(height: 4),
          for (final review in _reviews.take(3))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${review['user_name'] ?? '匿名同学'}：${(review['comment']?.toString().trim().isNotEmpty ?? false) ? review['comment'] : '这位同学没有留下文字评价'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                  ),
                  if (context.read<AuthProvider>().user?.id !=
                      (review['user_id'] as num?)?.toInt())
                    PopupMenuButton<String>(
                      tooltip: '举报评价',
                      padding: EdgeInsets.zero,
                      onSelected: (_) => _reportDishReview(
                          (review['id'] as num?)?.toInt() ?? 0),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'report', child: Text('举报该评价')),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _reportDishReview(int reviewId) async {
    if (reviewId == 0) return;
    await showRatingReportSheet(
      context: context,
      targetType: 'canteen_dish_review',
      targetId: reviewId,
      onSubmit: (reasonCode, description) async {
        try {
          final response = await context.read<AuthProvider>().dio.post(
            '/reports',
            data: {
              'target_type': 'canteen_dish_review',
              'target_id': reviewId,
              'reason_code': reasonCode,
              'reason': description.trim().isEmpty
                  ? '举报原因：$reasonCode'
                  : description.trim(),
            },
          );
          if (response.statusCode == 201 || response.statusCode == 200) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('举报已提交，感谢你的反馈')),
              );
            }
            return true;
          }
        } on DioException catch (error) {
          if (mounted) {
            final message = error.response?.data is Map
                ? error.response?.data['error']?.toString() ?? '举报提交失败'
                : '举报提交失败';
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          }
        }
        return false;
      },
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
          icon: const Icon(
            Icons.add_a_photo_rounded,
            size: 20,
          ),
          label: const Text('上传菜品实拍'),
        ),
      ],
    );
  }

  Widget _buildOfflineUploadNotice(bool isDark) {
    return Text(
      '所属商家已下架，暂不能新增菜品实拍或评价',
      style: TextStyle(
        fontSize: 12,
        color: CanteenTheme.textSecondaryColor(isDark),
      ),
    );
  }
}

/// 在商家详情页复用的上传 Sheet 入口。
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
  UploadedImage? _selectedImage;
  bool _submitting = false;
  late final TextEditingController _dishNameCtrl;

  /// 支持两种提交模式：
  /// - dishId 模式：选择已有菜品（从菜品详情页进入）
  /// - dish_name 模式：输入新菜名，服务端不存在时自动创建 CanteenDish
  bool get _hasDishTarget =>
      widget.dishId != null || _dishNameCtrl.text.trim().isNotEmpty;

  bool get _canSubmit => _fileId != null && _hasDishTarget;

  @override
  void initState() {
    super.initState();
    _dishNameCtrl = TextEditingController(text: widget.dishName ?? '');
  }

  @override
  void dispose() {
    _dishNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        // 键盘弹出/横屏/小屏时内容可滚动，避免 Column overflow。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        decoration: BoxDecoration(
          color: CanteenTheme.surfaceBg(isDark),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                  widget.dishId != null
                      ? (widget.dishName ?? '这道菜')
                      : '给这道菜起个名字',
                  style: TextStyle(
                    fontSize: 13,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
                if (widget.dishId == null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _dishNameCtrl,
                    textInputAction: TextInputAction.done,
                    maxLength: 40,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '输入菜名，例如：锅包肉',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: CanteenTheme.textTertiaryColor(isDark),
                      ),
                      prefixIcon:
                          const Icon(Icons.restaurant_rounded, size: 20),
                      filled: true,
                      fillColor: CanteenTheme.surfaceMutedBg(isDark),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(CanteenTheme.radiusMd),
                        borderSide: BorderSide(
                          color: CanteenTheme.borderColor(isDark),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(CanteenTheme.radiusMd),
                        borderSide: BorderSide(
                          color: CanteenTheme.borderColor(isDark),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(CanteenTheme.radiusMd),
                        borderSide: BorderSide(color: accent, width: 1.4),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  '请上传能清楚看到菜品主体的真实照片。提交后会进入审核，审核通过后才会公开展示。',
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
                            setState(() {
                              _fileId = images.first.fileId;
                              _selectedImage = images.first;
                            });
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
                      borderRadius:
                          BorderRadius.circular(CanteenTheme.radiusMd),
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
                      : const Text('确认上传'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedImage(bool isDark, Color accent) {
    final preview = _selectedImage?.previewBytes;
    final url = _selectedImage?.url ?? '';
    return Container(
      height: 140,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (preview != null)
            Image.memory(
              preview,
              fit: BoxFit.cover,
              // 本地字节可能损坏/非图片：解码失败时优雅回退占位图。
              errorBuilder: (_, __, ___) => _previewPlaceholder(isDark),
            )
          else if (url.isNotEmpty)
            CachedNetworkImage(
              imageUrl: ApiConstants.fullUrl(url),
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _previewPlaceholder(isDark),
              placeholder: (_, __) => _previewPlaceholder(isDark),
            )
          else
            _previewPlaceholder(isDark),
          Positioned(
            top: 6,
            right: 6,
            child: InkWell(
              onTap: () => setState(() {
                _fileId = null;
                _selectedImage = null;
              }),
              // 48dp 最小触控目标（Material 无障碍基线）。
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.close, size: 18, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewPlaceholder(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_rounded,
            size: 32,
            color: CanteenTheme.textTertiaryColor(isDark),
          ),
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
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final message = await widget.provider.submitDishSubmission(
      widget.canteenId,
      dishId: widget.dishId,
      dishName:
          widget.dishId != null ? widget.dishName : _dishNameCtrl.text.trim(),
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
