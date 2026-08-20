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
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/dish_gallery_section.dart';
import '../widgets/rating_detail/rating_report_sheet.dart';
import 'canteen_dish_detail_screen.dart' show showDishPhotoUploadSheet;
import 'canteen_dish_list_screen.dart';
import 'canteen_review_editor_screen.dart';

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

  bool get _isOffline {
    final raw = _canteenData?['canteen'];
    if (raw is! Map) return false;
    return raw['is_offline'] == true || raw['operating_status'] == 'offline';
  }

  Map<String, dynamic> get _reviewAction {
    final raw = _canteenData?['review_action'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  // 兼容旧服务端：缺少 review_action 时按原有“可以新增”处理，避免旧详情页被误锁死。
  bool get _canCreateReview => _reviewAction['can_create'] != false;

  bool get _canEditLatest =>
      _reviewAction['can_edit_latest'] == true &&
      _canteenData?['my_latest_review'] is Map;

  int? get _latestReviewId {
    final raw = _reviewAction['latest_review_id'] ??
        (_canteenData?['my_latest_review'] as Map?)?['review_event_id'];
    return raw is num ? raw.toInt() : int.tryParse('$raw');
  }

  String _reviewCooldownText() {
    final seconds =
        (_reviewAction['retry_after_seconds'] as num?)?.toInt() ?? 0;
    if (seconds <= 0) return '暂时不能新增评价';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600 + 59) ~/ 60;
    if (hours > 0) return '距下次评价还有 ${hours}小时${minutes}分钟';
    return '距下次评价还有 $minutes 分钟';
  }

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
      final errorMessage =
          context.watch<CanteenProvider>().errorMessage ?? '加载食堂详情失败，请检查网络后重试';
      return Scaffold(
        backgroundColor: CanteenTheme.pageBg(isDark),
        appBar: AppBar(
          title: Text(widget.canteenName),
          backgroundColor: CanteenTheme.surfaceBg(isDark),
        ),
        body: RefreshIndicator(
          onRefresh: _loadInitial,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.6,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.wifi_off_rounded,
                          size: 56,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          errorMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: _loadInitial,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('重新加载'),
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final rawDisplayReviews = _canteenData!['display_reviews'];
    final reviews = rawDisplayReviews is List
        ? rawDisplayReviews.whereType<Map>().map((raw) {
            final item = Map<String, dynamic>.from(raw);
            return item['review_source'] == 'v2'
                ? _normalizeV2Review(item)
                : {...item, 'review_source': 'legacy'};
          }).toList()
        : _buildLegacyReviewFallback();
    final ratingCount = (_canteenData!['reviewer_count'] as num?)?.toInt() ??
        (_canteenData!['rating_count'] as num?)?.toInt() ??
        0;

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
                    name: _canteenData?['canteen']?['name']?.toString() ?? '',
                    rating:
                        (_canteenData?['average_star'] as num?)?.toDouble() ??
                            0,
                    ratingCount: ratingCount,
                    dishCount: _dishCount,
                    dishPhotoCount: _dishPhotoCount,
                    offline: _isOffline,
                  ),
                  _buildDimensionSummary(isDark),
                  DishGallerySection(
                    canteenId: widget.canteenId,
                    canteenName: widget.canteenName,
                    onViewAll: _openDishList,
                    onUpload: _isOffline ? null : _openDishPhotoUpload,
                    onStatsChanged: (count, photos) {
                      if (!mounted) return;
                      if (count == _dishCount && photos == _dishPhotoCount) {
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
                    onWriteReview: _openPrimaryReviewEditor,
                    canWriteReview:
                        !_isOffline && (_canCreateReview || _canEditLatest),
                    latestReviewId: _latestReviewId,
                    onEditLatestReview: _openEditLatestReviewEditor,
                    onReport: _reportReview,
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

  Map<String, dynamic> _normalizeV2Review(Map raw) {
    final source = Map<String, dynamic>.from(raw);
    final scoreVersion = (source['score_version'] as num?)?.toInt() ?? 2;
    final dimensionScores = <String, dynamic>{
      'taste': source['taste_score'] ?? 0,
      'value': source['value_score'] ?? 0,
      'queue': source['queue_score'] ?? 0,
      'hygiene': source['hygiene_score'] ?? 0,
      'service': source['service_score'] ?? 0,
    };
    return {
      ...source,
      'star': source['overall_score'] ?? 0,
      'user_name': source['user_name'] ?? '匿名同学',
      'user_avatar': source['user_avatar'] ?? '',
      if (scoreVersion >= 2) 'dimension_scores': dimensionScores,
      'is_v2': scoreVersion >= 2,
      'review_source': 'v2',
      'score_version': scoreVersion,
      'helpful_count': source['helpful_count'] ?? 0,
      'unhelpful_count': source['unhelpful_count'] ?? 0,
    };
  }

  List<Map<String, dynamic>> _buildLegacyReviewFallback() {
    final rawV2Reviews = _canteenData!['reviews'];
    final normalizedV2 = rawV2Reviews is List
        ? rawV2Reviews.whereType<Map>().map(_normalizeV2Review).toList()
        : <Map<String, dynamic>>[];
    final v2UserIds = normalizedV2
        .map((item) => (item['user_id'] as num?)?.toInt())
        .whereType<int>()
        .toSet();
    final legacyOnly = (_canteenData!['ratings'] as List?)
            ?.whereType<Map>()
            .map((item) => {
                  ...Map<String, dynamic>.from(item),
                  'review_source': 'legacy',
                })
            .where((item) =>
                !v2UserIds.contains((item['user_id'] as num?)?.toInt()))
            .toList() ??
        <Map<String, dynamic>>[];
    return [...normalizedV2, ...legacyOnly];
  }

  Future<void> _reportReview(int reviewId, String source) async {
    final targetType = source == 'v2' ? 'canteen_review' : 'canteen_rating';
    await showRatingReportSheet(
      context: context,
      targetType: targetType,
      targetId: reviewId,
      onSubmit: (reasonCode, description) async {
        try {
          final response = await context.read<AuthProvider>().dio.post(
            '/reports',
            data: {
              'target_type': targetType,
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

  Widget _buildDimensionSummary(bool isDark) {
    final raw = _canteenData?['dimension_scores'];
    if (raw is! Map) return const SizedBox.shrink();
    final scores = Map<String, dynamic>.from(raw);
    final values = <({String key, String label})>[
      (key: 'taste', label: '味道'),
      (key: 'value', label: '性价比'),
      (key: 'queue', label: '排队'),
      (key: 'hygiene', label: '卫生'),
      (key: 'service', label: '服务'),
    ];
    final hasV2Score = values.any((item) {
      final value = scores[item.key];
      return value is num && value > 0;
    });
    if (!hasV2Score) return const SizedBox.shrink();
    final visitCount =
        (_canteenData?['visit_review_count'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
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
                Text(
                  '五维体验',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                const Spacer(),
                if (visitCount > 0)
                  Text(
                    '$visitCount 次到店评价 · 近一人一票',
                    style: TextStyle(
                      fontSize: 10,
                      color: CanteenTheme.textTertiaryColor(isDark),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: values.map((item) {
                final score = scores[item.key] is num
                    ? (scores[item.key] as num).toDouble()
                    : 0.0;
                return SizedBox(
                  width: 92,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 11,
                              color: CanteenTheme.textSecondaryColor(isDark),
                            ),
                          ),
                          Text(
                            score.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: CanteenTheme.accentStrongColor(isDark),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          minHeight: 5,
                          value: (score / 5).clamp(0.0, 1.0),
                          backgroundColor: CanteenTheme.surfaceMutedBg(isDark),
                          color: CanteenTheme.accentColor(isDark),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
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
                  ? CanteenStatusImage(
                      imageUrl: ApiConstants.fullUrl(imageUrl),
                      offline: _isOffline,
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
    final auth = context.watch<AuthProvider>();
    final ratingHint = _isOffline
        ? '该店已下架，历史评价仅供参考'
        : !auth.isLoggedIn
            ? '登录后可评价'
            : auth.user?.studentVerified != true
                ? '绑定教务后可评价'
                : _canCreateReview
                    ? '添加一条新的到店评价...'
                    : _canEditLatest
                        ? _reviewCooldownText()
                        : '暂时不能添加评价';

    final canOpenPrimary = !_isOffline && (_canCreateReview || _canEditLatest);

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
                onTap: canOpenPrimary ? _openPrimaryReviewEditor : null,
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
            onPressed: canOpenPrimary ? _openPrimaryReviewEditor : null,
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
              _canCreateReview ? '添加' : '修改最近一次',
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
          offline: _isOffline,
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

  Future<void> _voteRating(int ratingId, String source, String vote) async {
    if (_isVoting) return;
    if (!context.read<AuthProvider>().isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后操作')));
      return;
    }

    final oldData = _deepCopyCanteenData();
    setState(() {
      _isVoting = true;
      _applyLocalVote(ratingId, source, vote);
    });

    try {
      final provider = context.read<CanteenProvider>();
      final result = source == 'v2'
          ? await provider.voteReview(reviewId: ratingId, vote: vote)
          : await provider.voteRating(ratingId: ratingId, vote: vote);
      if (!mounted) return;
      if (result == null) {
        setState(() => _canteenData = oldData);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后再试')),
        );
        return;
      }
      setState(() => _reconcileVoteResult(result, source));
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

  void _applyLocalVote(int ratingId, String source, String newVote) {
    final keys = <String>[
      source == 'v2' ? 'reviews' : 'ratings',
      'display_reviews'
    ];
    for (final key in keys.toSet()) {
      final items = (_canteenData?[key] as List?)?.cast<dynamic>();
      if (items == null) continue;
      for (final item in items) {
        if (item is! Map) continue;
        final rating = item.cast<String, dynamic>();
        final itemSource = rating['review_source']?.toString() ??
            (rating['source']?.toString() ??
                (key == 'reviews' ? 'v2' : 'legacy'));
        if ((rating['id'] as num?)?.toInt() != ratingId ||
            itemSource != source) {
          continue;
        }
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
      }
    }
  }

  void _reconcileVoteResult(Map<String, dynamic> result, String source) {
    final ratingId =
        ((result['rating_id'] ?? result['review_id']) as num?)?.toInt();
    if (ratingId == null) return;

    final keys = <String>[
      source == 'v2' ? 'reviews' : 'ratings',
      'display_reviews'
    ];
    for (final key in keys.toSet()) {
      final ratings = (_canteenData?[key] as List?)?.cast<dynamic>();
      if (ratings == null) continue;
      for (final item in ratings) {
        if (item is! Map) continue;
        final rating = item.cast<String, dynamic>();
        final itemSource = rating['review_source']?.toString() ??
            (rating['source']?.toString() ??
                (key == 'reviews' ? 'v2' : 'legacy'));
        if ((rating['id'] as num?)?.toInt() != ratingId ||
            itemSource != source) {
          continue;
        }
        rating['helpful_count'] = result['helpful_count'] ?? 0;
        rating['unhelpful_count'] = result['unhelpful_count'] ?? 0;
        rating['my_vote'] = result['my_vote'];
      }
    }
  }

  // ── 打开评价编辑器全屏页 ────────────────────────────────────────

  Future<bool> _ensureCanReview() async {
    if (_isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该店当前已下架，暂不能发布新的评价')),
      );
      return false;
    }
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后评价')));
      return false;
    }
    if (auth.user?.studentVerified != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先绑定教务账号后再评价')),
      );
      return false;
    }
    return true;
  }

  Future<void> _openPrimaryReviewEditor() async {
    if (_canCreateReview) {
      await _openCreateReviewEditor();
    } else {
      await _openEditLatestReviewEditor();
    }
  }

  Future<void> _openCreateReviewEditor() async {
    if (!await _ensureCanReview()) return;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CanteenReviewEditorScreen(
          canteenId: widget.canteenId,
          canteenName: widget.canteenName,
          canteenImage: _canteenData?['canteen']?['image']?.toString(),
          averageStar:
              (_canteenData?['average_star'] as num?)?.toDouble() ?? 0.0,
          ratingCount: (_canteenData?['rating_count'] as num?)?.toInt() ?? 0,
          dishCount: _dishCount,
          dishPhotoCount: _dishPhotoCount,
          mode: CanteenReviewEditorMode.create,
          existingReview: null,
        ),
      ),
    );

    if (result == true && mounted) {
      await _reloadSilently();
    }
  }

  Future<void> _openEditLatestReviewEditor() async {
    if (!await _ensureCanReview()) return;
    final latest = _canteenData?['my_latest_review'];
    if (!_canEditLatest || latest is! Map || _latestReviewId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最近一条评价暂时不可修改，请刷新后重试')),
      );
      return;
    }

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CanteenReviewEditorScreen(
          canteenId: widget.canteenId,
          canteenName: widget.canteenName,
          canteenImage: _canteenData?['canteen']?['image']?.toString(),
          averageStar:
              (_canteenData?['average_star'] as num?)?.toDouble() ?? 0.0,
          ratingCount: (_canteenData?['rating_count'] as num?)?.toInt() ?? 0,
          dishCount: _dishCount,
          dishPhotoCount: _dishPhotoCount,
          mode: CanteenReviewEditorMode.edit,
          existingReview: Map<String, dynamic>.from(latest),
        ),
      ),
    );

    if (result == true && mounted) {
      await _reloadSilently();
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
                          side:
                              BorderSide(color: accent.withValues(alpha: 0.4)),
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
                                  borderRadius: BorderRadius.circular(
                                      CanteenTheme.radiusMd),
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
                                  borderRadius: BorderRadius.circular(
                                      CanteenTheme.radiusMd),
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
