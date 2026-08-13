import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../config/api_constants.dart';
import '../widgets/canteen/canteen_detail_header.dart';
import '../widgets/canteen/canteen_detail_skeleton.dart';
import '../widgets/canteen/canteen_review_section.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/dish_gallery_section.dart';
import 'canteen_dish_detail_screen.dart' show showDishPhotoUploadSheet;
import 'canteen_dish_list_screen.dart';

/// 食堂详情页：Hero + 信息区 + 大家都在吃 + 评价区 + 底部写评价。
///
/// Loading 拆两层：
/// - [_initialLoading]：首次进入，展示 [CanteenDetailSkeleton]
/// - [_reviewsRefreshing]：筛选/排序切换，只刷新评价区（顶部 2px 进度条）
/// - [_requestGeneration]：丢弃陈旧响应，防止快速切换被慢请求覆盖
class CanteenDetailScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;

  /// 列表页传入的统计（详情接口不返回这两项，避免新造字段）。
  final int dishCount;
  final int dishPhotoCount;

  const CanteenDetailScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
    this.dishCount = 0,
    this.dishPhotoCount = 0,
  });

  @override
  State<CanteenDetailScreen> createState() => _CanteenDetailScreenState();
}

class _CanteenDetailScreenState extends State<CanteenDetailScreen> {
  Map<String, dynamic>? _canteenData;
  bool _initialLoading = true;
  bool _reviewsRefreshing = false;
  bool _isVoting = false;
  int _requestGeneration = 0;
  int _reviewDataVersion = 0;

  // UI 当前选择（点击即切换，立即反馈选中态）
  String _reviewSort = 'best';
  String _reviewFilter = 'all';

  // _canteenData 实际对应的「最后成功 applied」状态。
  // 失败回滚时以 applied 为准，而不是上一个瞬时 UI 状态，
  // 避免「with_image 失败 → 回滚到 high → 标签 high 但数据仍是 all」错位。
  String _appliedReviewSort = 'best';
  String _appliedReviewFilter = 'all';

  // 菜品/实拍统计：初值来自列表页入口快照，随后由图鉴区真实数据刷新
  late int _dishCount;
  late int _dishPhotoCount;

  @override
  void initState() {
    super.initState();
    _dishCount = widget.dishCount;
    _dishPhotoCount = widget.dishPhotoCount;
    _loadInitial();
  }

  // ── Loading 状态机 ─────────────────────────────────────────────

  /// 首次进入：整页 skeleton，不出现中央 spinner。
  Future<void> _loadInitial() async {
    final generation = ++_requestGeneration;
    setState(() => _initialLoading = true);
    final data = await context.read<CanteenProvider>().loadCanteenDetail(
          widget.canteenId,
          reviewSort: _appliedReviewSort,
          reviewFilter: _appliedReviewFilter,
        );
    if (!mounted || generation != _requestGeneration) return;
    setState(() {
      if (data.isNotEmpty && data['canteen'] != null) {
        _canteenData = data;
        _appliedReviewSort = _reviewSort;
        _appliedReviewFilter = _reviewFilter;
        _reviewDataVersion++;
      }
      _initialLoading = false;
    });
  }

  /// 筛选/排序切换：Hero、店铺信息、菜品区一律不动，只刷新评价区。
  /// 参数在发起请求时冻结，不读取可变全局。
  /// 返回三态：
  /// - `true`：成功应用（同步更新 applied 状态）
  /// - `false`：请求失败（调用方恢复 UI 为 applied 状态并提示）
  /// - `null`：已被更新的请求取代（stale，调用方不做任何事）
  Future<bool?> _refreshReviews({
    required String sort,
    required String filter,
  }) async {
    final generation = ++_requestGeneration;
    setState(() => _reviewsRefreshing = true);
    final data = await context.read<CanteenProvider>().loadCanteenDetail(
          widget.canteenId,
          reviewSort: sort,
          reviewFilter: filter,
        );
    if (!mounted || generation != _requestGeneration) return null;
    final success = data.isNotEmpty && data['canteen'] != null;
    setState(() {
      if (success) {
        _canteenData = data;
        _appliedReviewSort = sort;
        _appliedReviewFilter = filter;
        _reviewDataVersion++;
      }
      _reviewsRefreshing = false;
    });
    return success;
  }

  /// 静默整页刷新（评价提交 / 菜品页返回后），不显示任何 loading。
  Future<void> _reloadSilently() async {
    final generation = ++_requestGeneration;
    // 若评价区还有在途刷新，先归位，避免被陈旧响应留下 refreshing 状态
    if (_reviewsRefreshing) {
      setState(() => _reviewsRefreshing = false);
    }
    final data = await context.read<CanteenProvider>().loadCanteenDetail(
          widget.canteenId,
          reviewSort: _appliedReviewSort,
          reviewFilter: _appliedReviewFilter,
        );
    if (!mounted || generation != _requestGeneration) return;
    setState(() {
      if (data.isNotEmpty && data['canteen'] != null) {
        _canteenData = data;
        _reviewDataVersion++;
      }
    });
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);

    if (_initialLoading) {
      return Scaffold(
        backgroundColor: CanteenTheme.pageBg(isDark),
        body: const CanteenDetailSkeleton(),
      );
    }
    if (_canteenData == null || _canteenData!['canteen'] == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.canteenName)),
        body: const Center(child: Text('加载失败')),
      );
    }

    final reviews = (_canteenData!['ratings'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];
    final ratingCount = (_canteenData!['rating_count'] as num?)?.toInt() ?? 0;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: CanteenTheme.pageBg(isDark),
        bottomNavigationBar: _buildFloatingRatingComposer(isDark, accent),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeroSection()),
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CanteenDetailHeader(
                    name:
                        _canteenData?['canteen']?['name']?.toString() ?? '',
                    rating:
                        (_canteenData?['average_star'] as num?)?.toDouble() ??
                            0,
                    ratingCount: ratingCount,
                    dishCount: _dishCount,
                    dishPhotoCount: _dishPhotoCount,
                  ),
                  DishGallerySection(
                    canteenId: widget.canteenId,
                    canteenName: widget.canteenName,
                    onViewAll: _openDishList,
                    onUpload: _openDishPhotoUpload,
                    onStatsChanged: (count, photos) {
                      if (!mounted) return;
                      if (count == _dishCount &&
                          photos == _dishPhotoCount) {
                        return;
                      }
                      setState(() {
                        _dishCount = count;
                        _dishPhotoCount = photos;
                      });
                    },
                  ),
                  CanteenReviewSection(
                    reviews: reviews,
                    reviewCount: ratingCount,
                    sort: _reviewSort,
                    filter: _reviewFilter,
                    dataVersion: _reviewDataVersion,
                    isRefreshing: _reviewsRefreshing,
                    isVoting: _isVoting,
                    currentUserId: context.read<AuthProvider>().user?.id,
                    onSortChanged: (value) async {
                      if (_reviewSort == value) return;
                      setState(() => _reviewSort = value);
                      final result = await _refreshReviews(
                        sort: value,
                        filter: _reviewFilter,
                      );
                      if (!mounted) return;
                      if (result == false) {
                        // 恢复为「最后成功 applied」状态（sort/filter 一起回滚）
                        setState(() {
                          _reviewSort = _appliedReviewSort;
                          _reviewFilter = _appliedReviewFilter;
                        });
                        _showRefreshFailed();
                      }
                    },
                    onFilterChanged: (value) async {
                      if (_reviewFilter == value) return;
                      setState(() => _reviewFilter = value);
                      final result = await _refreshReviews(
                        sort: _reviewSort,
                        filter: value,
                      );
                      if (!mounted) return;
                      if (result == false) {
                        setState(() {
                          _reviewSort = _appliedReviewSort;
                          _reviewFilter = _appliedReviewFilter;
                        });
                        _showRefreshFailed();
                      }
                    },
                    onVote: _voteRating,
                    onWriteReview: _showRatingSheet,
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 104)),
          ],
        ),
      ),
    );
  }

  // ── Hero ───────────────────────────────────────────────────────

  Widget _buildHeroSection() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final imageUrl = _canteenData?['canteen']?['image']?.toString() ?? '';
    final hasImage = imageUrl.isNotEmpty;
    final heroHeight =
        (MediaQuery.of(context).size.width * 0.5).clamp(190.0, 230.0);

    final authUser = context.read<AuthProvider>().user;
    final isAdmin =
        authUser?.role == 'admin' || authUser?.role == 'super_admin';

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(CanteenTheme.radiusLg),
      ),
      child: SizedBox(
        height: heroHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'canteen-${widget.canteenId}',
              child: hasImage
                  ? CachedNetworkImage(
                      imageUrl: ApiConstants.fullUrl(imageUrl),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          _buildImagePlaceholder(isDark),
                      placeholder: (_, __) => _buildImagePlaceholder(isDark),
                    )
                  : _buildImagePlaceholder(isDark),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.22),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.24),
                  ],
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 16,
              child: _buildCircleButton(
                icon: Icons.arrow_back,
                onTap: () => Navigator.pop(context),
              ),
            ),
            if (isAdmin)
              Positioned(
                top: MediaQuery.of(context).padding.top + 10,
                right: 16,
                child: _buildCircleButton(
                  icon: Icons.edit_rounded,
                  onTap: _showEditImageSheet,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder(bool isDark) {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restaurant_rounded,
              size: 44,
              color: Color(0xFF9FA7B5),
            ),
            SizedBox(height: 8),
            Text(
              '暂无封面',
              style: TextStyle(color: Color(0xFF8A94A6), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  // ── 底部写评价 ────────────────────────────────────────────────

  Widget _buildFloatingRatingComposer(bool isDark, Color accent) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final hasRating = _canteenData?['my_rating'] != null;
    final auth = context.watch<AuthProvider>();
    final ratingHint = !auth.isLoggedIn
        ? '登录后可评价'
        : auth.user?.studentVerified != true
            ? '绑定教务后可评价'
            : hasRating
                ? '修改我的评价...'
                : '写下你的真实体验...';

    return Container(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 8),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        border: Border(
          top: BorderSide(color: CanteenTheme.borderColor(isDark)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                onTap: _showRatingSheet,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: CanteenTheme.surfaceMutedBg(isDark),
                    borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    ratingHint,
                    style: TextStyle(
                      fontSize: 13,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _showRatingSheet,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(74, 44),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
              ),
            ),
            child: Text(
              hasRating ? '修改' : '写评价',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDishList() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CanteenDishListScreen(
          canteenId: widget.canteenId,
          canteenName: widget.canteenName,
        ),
      ),
    );
    if (mounted) await _reloadSilently();
  }

  /// 空图鉴「上传菜品实拍」：直接打开上传 Sheet（dish_name 模式），
  /// 不再经由菜品列表页的空列表死路。
  Future<void> _openDishPhotoUpload() async {
    final success = await showDishPhotoUploadSheet(
      context,
      canteenId: widget.canteenId,
      provider: context.read<CanteenProvider>(),
    );
    if (success == true && mounted) {
      await _reloadSilently();
    }
  }

  void _showRefreshFailed() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('刷新失败，请重试')),
    );
  }

  // ── 投票（乐观更新，逻辑与重构前一致）───────────────────────────

  Future<void> _voteRating(int ratingId, String vote) async {
    if (_isVoting) return;
    if (!context.read<AuthProvider>().isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后操作')));
      return;
    }

    final oldData = _deepCopyCanteenData();
    setState(() {
      _isVoting = true;
      _applyLocalVote(ratingId, vote);
    });

    try {
      final result = await context.read<CanteenProvider>().voteRating(
            ratingId: ratingId,
            vote: vote,
          );
      if (!mounted) return;
      if (result == null) {
        setState(() => _canteenData = oldData);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后再试')),
        );
        return;
      }
      setState(() => _reconcileVoteResult(result));
    } finally {
      if (mounted) {
        setState(() => _isVoting = false);
      }
    }
  }

  Map<String, dynamic>? _deepCopyCanteenData() {
    if (_canteenData == null) return null;
    return jsonDecode(jsonEncode(_canteenData)) as Map<String, dynamic>;
  }

  void _applyLocalVote(int ratingId, String newVote) {
    final ratings = (_canteenData?['ratings'] as List?)?.cast<dynamic>();
    if (ratings == null) return;

    for (final item in ratings) {
      if (item is! Map) continue;
      final rating = item.cast<String, dynamic>();
      if ((rating['id'] as num?)?.toInt() != ratingId) continue;

      final oldVote = rating['my_vote']?.toString();
      var helpful = (rating['helpful_count'] as num?)?.toInt() ?? 0;
      var unhelpful = (rating['unhelpful_count'] as num?)?.toInt() ?? 0;

      if (oldVote == 'up') helpful--;
      if (oldVote == 'down') unhelpful--;
      if (newVote == 'up') helpful++;
      if (newVote == 'down') unhelpful++;

      rating['helpful_count'] = helpful < 0 ? 0 : helpful;
      rating['unhelpful_count'] = unhelpful < 0 ? 0 : unhelpful;
      rating['my_vote'] = newVote == 'none' ? null : newVote;
      break;
    }
  }

  void _reconcileVoteResult(Map<String, dynamic> result) {
    final ratingId = (result['rating_id'] as num?)?.toInt();
    if (ratingId == null) return;

    final ratings = (_canteenData?['ratings'] as List?)?.cast<dynamic>();
    if (ratings == null) return;

    for (final item in ratings) {
      if (item is! Map) continue;
      final rating = item.cast<String, dynamic>();
      if ((rating['id'] as num?)?.toInt() != ratingId) continue;
      rating['helpful_count'] = result['helpful_count'] ?? 0;
      rating['unhelpful_count'] = result['unhelpful_count'] ?? 0;
      rating['my_vote'] = result['my_vote'];
      break;
    }
  }

  // ── 写评价 Sheet（完整五颗交互星只在评分 Sheet 出现）──────────────

  Future<void> _showRatingSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后评价')));
      return;
    }
    if (auth.user?.studentVerified != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先绑定教务账号后再评价')),
      );
      return;
    }

    final myRating = _canteenData?['my_rating'];
    var selectedStar = (myRating?['star'] as num?)?.toInt() ?? 0;
    var isSubmitting = false;
    final controller = TextEditingController(
      text: myRating?['comment']?.toString() ?? '',
    );

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (context, setSheetState) {
              Future<void> submitRating() async {
                if (selectedStar == 0 || isSubmitting) return;
                setSheetState(() => isSubmitting = true);
                final result =
                    await context.read<CanteenProvider>().rateCanteen(
                          widget.canteenId,
                          selectedStar,
                          controller.text.trim(),
                        );
                if (!context.mounted) return;
                setSheetState(() => isSubmitting = false);
                if (result) {
                  Navigator.pop(sheetContext);
                  await _reloadSilently();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('提交失败，请稍后再试')),
                  );
                }
              }

              return Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  decoration: BoxDecoration(
                    color: CanteenTheme.surfaceBg(isDark),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                          myRating == null ? '写评价' : '修改评价',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: CanteenTheme.textPrimaryColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '给这个食堂打个分，顺便说说真实体验',
                          style: TextStyle(
                            fontSize: 13,
                            color: CanteenTheme.textSecondaryColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: List.generate(5, (index) {
                            final value = index + 1;
                            final selected = value <= selectedStar;
                            return IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              onPressed: isSubmitting
                                  ? null
                                  : () {
                                      setSheetState(() {
                                        selectedStar = value;
                                      });
                                    },
                              icon: Icon(
                                selected
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: accent,
                                size: 34,
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: controller,
                          maxLines: 5,
                          minLines: 4,
                          maxLength: 200,
                          enabled: !isSubmitting,
                          decoration: InputDecoration(
                            hintText: '比如味道、价格、排队情况、推荐窗口...',
                            hintStyle: TextStyle(
                                color: CanteenTheme.textSecondaryColor(isDark)),
                            filled: true,
                            fillColor: CanteenTheme.surfaceMutedBg(isDark),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.all(16),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: FilledButton(
                            onPressed: selectedStar == 0 || isSubmitting
                                ? null
                                : submitRating,
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: isSubmitting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    myRating == null ? '发布评价' : '保存修改',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  // ── 管理员编辑封面（逻辑与重构前一致）────────────────────────────

  void _showEditImageSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CanteenTheme.accentColor(isDark);
    final currentImage = _canteenData!['canteen']['image']?.toString() ?? '';
    CroppedFile? pendingCoverFile;
    Uint8List? pendingCoverBytes;
    bool isUploadingCover = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> pickCover() async {
              final cropped = await _pickAndCropCanteenCover(context, accent);
              if (cropped == null) return;
              final bytes = await cropped.readAsBytes();
              if (!context.mounted) return;
              setSheetState(() {
                pendingCoverFile = cropped;
                pendingCoverBytes = bytes;
              });
            }

            Future<void> saveCover() async {
              if (isUploadingCover) return;
              if (pendingCoverFile == null || pendingCoverBytes == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请先选择并裁剪封面图片')),
                );
                return;
              }

              setSheetState(() => isUploadingCover = true);
              final messenger = ScaffoldMessenger.of(context);
              final uploadedUrl = await _uploadCroppedCover(pendingCoverBytes!);
              if (!mounted || !sheetContext.mounted) return;

              if (uploadedUrl == null) {
                setSheetState(() => isUploadingCover = false);
                messenger.showSnackBar(
                  const SnackBar(content: Text('图片上传失败')),
                );
                return;
              }

              final result = await context
                  .read<CanteenProvider>()
                  .updateCanteenImage(widget.canteenId, uploadedUrl);
              if (!mounted || !sheetContext.mounted) return;

              setSheetState(() => isUploadingCover = false);
              if (result != null) {
                Navigator.pop(sheetContext);
                messenger.showSnackBar(
                  const SnackBar(content: Text('食堂图片已更新')),
                );
                setState(() {
                  _canteenData!['canteen'] = result;
                });
              } else {
                messenger.showSnackBar(
                  const SnackBar(content: Text('更新失败')),
                );
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                decoration: BoxDecoration(
                  color: CanteenTheme.surfaceBg(isDark),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: SafeArea(
                  top: false,
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
                        '编辑食堂封面',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: CanteenTheme.textPrimaryColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '建议上传横向图片，可拖动和缩放裁剪区域，主体尽量放中间',
                        style: TextStyle(
                          fontSize: 13,
                          color: CanteenTheme.textSecondaryColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 16),
                      AspectRatio(
                        aspectRatio: 2,
                        child: ClipRRect(
                          borderRadius:
                              BorderRadius.circular(CanteenTheme.radiusMd),
                          child: _buildCoverPreview(
                            currentImage: currentImage,
                            pendingCoverBytes: pendingCoverBytes,
                            isDark: isDark,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: isUploadingCover ? null : pickCover,
                        icon: const Icon(Icons.crop_rounded),
                        label: Text(
                          pendingCoverFile == null ? '选择图片并裁剪' : '重新选择图片',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accent,
                          side: BorderSide(
                              color: accent.withValues(alpha: 0.4)),
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(CanteenTheme.radiusMd),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: isUploadingCover
                                  ? null
                                  : () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(46),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(CanteenTheme.radiusMd),
                                ),
                              ),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: isUploadingCover ? null : saveCover,
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(46),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(CanteenTheme.radiusMd),
                                ),
                              ),
                              child: isUploadingCover
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      '保存图片',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCoverPreview({
    required String currentImage,
    required Uint8List? pendingCoverBytes,
    required bool isDark,
  }) {
    if (pendingCoverBytes != null) {
      return Image.memory(
        pendingCoverBytes,
        fit: BoxFit.cover,
      );
    }

    if (currentImage.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: ApiConstants.fullUrl(currentImage),
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _buildCoverPreviewPlaceholder(isDark),
        placeholder: (_, __) => _buildCoverPreviewPlaceholder(isDark),
      );
    }

    return _buildCoverPreviewPlaceholder(isDark);
  }

  Widget _buildCoverPreviewPlaceholder(bool isDark) {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restaurant_rounded,
              size: 32,
              color: Color(0xFF9FA7B5),
            ),
            SizedBox(height: 6),
            Text(
              '暂无封面',
              style: TextStyle(color: Color(0xFF8A94A6), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Future<CroppedFile?> _pickAndCropCanteenCover(
    BuildContext cropContext,
    Color accent,
  ) async {
    final cropperUiSettings = [
      AndroidUiSettings(
        toolbarTitle: '调整食堂封面',
        toolbarColor: accent,
        toolbarWidgetColor: Colors.white,
        lockAspectRatio: true,
        hideBottomControls: false,
      ),
      IOSUiSettings(
        title: '调整食堂封面',
        aspectRatioLockEnabled: true,
      ),
      WebUiSettings(
        context: cropContext,
        presentStyle: WebPresentStyle.dialog,
        initialAspectRatio: 2,
      ),
    ];

    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 95,
      requestFullMetadata: false,
    );
    if (picked == null) return null;

    return ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 2, ratioY: 1),
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 88,
      maxWidth: 1600,
      maxHeight: 800,
      uiSettings: cropperUiSettings,
    );
  }

  Future<String?> _uploadCroppedCover(Uint8List bytes) async {
    try {
      final dio = context.read<AuthProvider>().dio;
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename:
              'canteen_cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ),
      });

      final response = await dio.post(
        '/upload',
        data: formData,
        options: Options(
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

      if (response.statusCode == 200 &&
          response.data != null &&
          response.data['url'] != null) {
        return response.data['url'].toString();
      }
    } on DioException catch (e) {
      debugPrint('上传食堂封面失败: ${e.type} status=${e.response?.statusCode}');
    } catch (e) {
      debugPrint('处理食堂封面失败: ${e.runtimeType}');
    }
    return null;
  }
}
