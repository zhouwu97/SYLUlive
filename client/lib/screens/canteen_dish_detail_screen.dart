import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';

import '../config/api_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/rating_detail/rating_report_sheet.dart';
import '../widgets/canteen/dish_photo_mosaic.dart';

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
    final results = await Future.wait<dynamic>([
      provider.loadDishDetail(widget.canteenId, widget.dishId),
      provider.loadDishReviews(widget.dishId),
    ]);
    final data = results[0] as Map<String, dynamic>?;
    final reviews = results[1] as List<Map<String, dynamic>>?;
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
                      '${(_data?['mention_count'] as num?)?.toInt() ?? (_data?['reviewer_count'] as num?)?.toInt() ?? _reviews.length} 人评价中提到 · $_photoCount 张同学真实实拍',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: CanteenTheme.textPrimaryColor(isDark),
                      ),
                    ),
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

  Widget _buildReviewList(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '大家怎么说',
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
                      onSelected: (_) => _reportDishReview(review),
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

  Future<void> _reportDishReview(Map<String, dynamic> review) async {
    final dishReviewId = (review['dish_review_id'] as num?)?.toInt() ?? 0;
    final parentReviewId = (review['review_id'] as num?)?.toInt() ??
        (review['id'] as num?)?.toInt() ??
        0;
    final isParentReview = review['review_source'] == 'canteen_review_event';
    final targetType = !isParentReview && dishReviewId > 0
        ? 'canteen_dish_review'
        : 'canteen_review';
    final targetId =
        targetType == 'canteen_dish_review' ? dishReviewId : parentReviewId;
    if (targetId == 0) return;
    await showRatingReportSheet(
      context: context,
      targetType: targetType,
      targetId: targetId,
      onSubmit: (reasonCode, description) async {
        try {
          final response = await context.read<AuthProvider>().dio.post(
            '/reports',
            data: {
              'target_type': targetType,
              'target_id': targetId,
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
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: Row(
        children: [
          Icon(Icons.rate_review_outlined, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '发表食堂评价时关联「${widget.dishName}」，上传实拍即可同步展示在此处。',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
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
