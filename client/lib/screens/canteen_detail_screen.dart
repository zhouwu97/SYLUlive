import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../widgets/image_upload_widget.dart';
import '../config/api_constants.dart';

class CanteenDetailScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  const CanteenDetailScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
  });

  @override
  State<CanteenDetailScreen> createState() => _CanteenDetailScreenState();
}

class _CanteenDetailScreenState extends State<CanteenDetailScreen> {
  final _commentCtrl = TextEditingController();
  int _star = 0;
  List<String> _ratingImages = [];
  Map<String, dynamic>? _canteenData;
  bool _isLoading = true;
  bool _isVoting = false;
  String _reviewSort = 'best';
  String _reviewFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (mounted) setState(() => _isLoading = true);
    final data = await context.read<CanteenProvider>().loadCanteenDetail(
          widget.canteenId,
          reviewSort: _reviewSort,
          reviewFilter: _reviewFilter,
        );
    if (mounted) {
      setState(() {
        _canteenData = data;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_canteenData == null || _canteenData!['canteen'] == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.canteenName)),
        body: const Center(child: Text('加载失败')),
      );
    }

    final reviews =
        (_canteenData!['ratings'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7FB),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeroSection()),
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: _buildInfoCard(),
                  ),
                  const SizedBox(height: 16),
                  _buildMyRatingCard(),
                  _buildReviewHeader(reviews.length),
                ],
              ),
            ),
            if (reviews.isEmpty)
              SliverToBoxAdapter(child: _buildEmptyReviews())
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildReviewItem(reviews[index]),
                  childCount: reviews.length,
                ),
              ),
            const SliverToBoxAdapter(
              child: SizedBox(height: 32),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroSection() {
    final imageUrl = _canteenData?['canteen']?['image']?.toString() ?? '';
    final hasImage = imageUrl.isNotEmpty;
    final heroHeight = hasImage ? 220.0 : 200.0;

    final authUser = context.read<AuthProvider>().user;
    final isAdmin =
        authUser?.role == 'admin' || authUser?.role == 'super_admin';

    return SizedBox(
      height: heroHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: ApiConstants.fullUrl(imageUrl),
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _buildImagePlaceholder(),
              placeholder: (_, __) => _buildImagePlaceholder(),
            )
          else
            _buildImagePlaceholder(),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.28),
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
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFE9ECF3),
            Color(0xFFDDE2EC),
          ],
        ),
      ),
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
              style: TextStyle(
                color: Color(0xFF8A94A6),
                fontSize: 12,
              ),
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
          width: 42,
          height: 42,
          child: Icon(
            icon,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    final name = _canteenData?['canteen']?['name']?.toString() ?? '';
    final rating = (_canteenData?['average_star'] as num?)?.toDouble() ?? 0;
    final count = (_canteenData?['rating_count'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF151821),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _stars(rating, 20),
                    const SizedBox(width: 8),
                    Text(
                      '$count 人评价',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF7A8190),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: 76,
            padding: const EdgeInsets.symmetric(vertical: 10),
            margin: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4D8),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  rating.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFFA800),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '综合评分',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9B7A22),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyRatingCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEDEFF5)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我的评价',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '分享你的真实体验，帮助同学避坑',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9AA0AA),
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: _showRatingDialog,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFFB300),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              minimumSize: const Size(74, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            child: const Text('去评分'),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewHeader(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '用户评价',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF151821),
                ),
              ),
              const SizedBox(width: 8),
              _buildCountBadge('$count 条'),
              const Spacer(),
              _buildSortChip('best', '综合'),
              const SizedBox(width: 8),
              _buildSortChip('latest', '最新'),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip('all', '全部'),
                const SizedBox(width: 8),
                _buildFilterChip('with_image', '有图'),
                const SizedBox(width: 8),
                _buildFilterChip('high', '高分'),
                const SizedBox(width: 8),
                _buildFilterChip('low', '低分'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFF7A8190),
        ),
      ),
    );
  }

  Widget _buildSortChip(String value, String label) {
    final selected = _reviewSort == value;
    return GestureDetector(
      onTap: () async {
        if (selected) return;
        setState(() => _reviewSort = value);
        await _loadData();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFA800) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFFFFA800) : const Color(0xFFE6E8EF),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : const Color(0xFF606775),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final selected = _reviewFilter == value;
    return GestureDetector(
      onTap: () async {
        if (selected) return;
        setState(() => _reviewFilter = value);
        await _loadData();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF4D8) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFFFFD27A) : const Color(0xFFE6E8EF),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? const Color(0xFFFFA800) : const Color(0xFF606775),
          ),
        ),
      ),
    );
  }

  Widget _buildReviewItem(Map<String, dynamic> review) {
    final id = (review['id'] as num?)?.toInt() ?? 0;
    final userId = (review['user_id'] as num?)?.toInt() ?? 0;
    final currentUserId = context.read<AuthProvider>().user?.id;
    final nickname = review['user_name']?.toString() ?? '匿名同学';
    final content = review['comment']?.toString() ?? '';
    final avatar = review['user_avatar']?.toString() ?? '';
    final rating = (review['star'] as num?)?.toDouble() ?? 0;
    final helpfulCount = (review['helpful_count'] as num?)?.toInt() ?? 0;
    final unhelpfulCount = (review['unhelpful_count'] as num?)?.toInt() ?? 0;
    final myVote = review['my_vote']?.toString();
    final isOwnRating = currentUserId != null && currentUserId == userId;
    final imgList = _parseImageList(review['images']);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEDEFF5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _stars(rating, 15),
              const SizedBox(width: 8),
              Text(
                '${rating.toStringAsFixed(1)}分',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFFFA800),
                ),
              ),
            ],
          ),
          if (content.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              content,
              style: const TextStyle(
                fontSize: 15,
                height: 1.55,
                fontWeight: FontWeight.w500,
                color: Color(0xFF252A33),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            const Text(
              '这位同学没有留下文字评价',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFFA0A6B2),
              ),
            ),
          ],
          if (imgList.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: imgList
                    .map(
                      (url) => ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: ApiConstants.fullUrl(url),
                          width: 82,
                          height: 82,
                          fit: BoxFit.cover,
                          placeholder: (context, url) =>
                              Container(color: Colors.grey[200]),
                          errorWidget: (context, url, error) => const Icon(
                            Icons.broken_image,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              _buildSmallAvatar(avatar),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _reviewAuthorText(nickname, review['created_at']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8A92A3),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (!isOwnRating) ...[
                _buildVoteButton(
                  icon: Icons.thumb_up_alt_rounded,
                  count: helpfulCount,
                  selected: myVote == 'up',
                  onTap: _isVoting
                      ? null
                      : () => _voteRating(id, myVote == 'up' ? 'none' : 'up'),
                ),
                const SizedBox(width: 8),
                _buildVoteButton(
                  icon: Icons.thumb_down_alt_rounded,
                  count: unhelpfulCount,
                  selected: myVote == 'down',
                  onTap: _isVoting
                      ? null
                      : () =>
                          _voteRating(id, myVote == 'down' ? 'none' : 'down'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSmallAvatar(String avatar) {
    return CircleAvatar(
      radius: 11,
      backgroundColor: const Color(0xFFE9ECF3),
      backgroundImage: avatar.isNotEmpty
          ? CachedNetworkImageProvider(ApiConstants.fullUrl(avatar))
          : null,
      child: avatar.isEmpty
          ? const Icon(
              Icons.person_rounded,
              size: 12,
              color: Color(0xFF9AA3B2),
            )
          : null,
    );
  }

  Widget _buildVoteButton({
    required IconData icon,
    required int count,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF4D8) : const Color(0xFFF6F7FB),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFFFFD27A) : const Color(0xFFE8EAF0),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color:
                  selected ? const Color(0xFFFFA800) : const Color(0xFF8A92A3),
            ),
            const SizedBox(width: 4),
            Text(
              count.toString(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected
                    ? const Color(0xFFFFA800)
                    : const Color(0xFF8A92A3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyReviews() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEDEFF5)),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.rate_review_rounded,
            size: 30,
            color: Color(0xFFB5BCCB),
          ),
          const SizedBox(height: 10),
          Text(
            _emptyReviewTitle(),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF252A33),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _emptyReviewSubtitle(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF8A92A3),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _parseImageList(dynamic rawImages) {
    if (rawImages == null || rawImages.toString().isEmpty) return [];
    try {
      final decoded = jsonDecode(rawImages.toString());
      if (decoded is List) {
        return decoded
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
    } catch (e) {
      // ignore parsing error
    }
    return [];
  }

  String _reviewAuthorText(String nickname, dynamic createdAt) {
    final date = _formatShortDate(createdAt?.toString() ?? '');
    if (date.isEmpty) return nickname;
    return '$nickname · $date';
  }

  String _formatShortDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return '';
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '$month-$day';
  }

  String _emptyReviewTitle() {
    switch (_reviewFilter) {
      case 'with_image':
        return '暂无有图评价';
      case 'high':
        return '暂无高分评价';
      case 'low':
        return '暂无低分评价';
      default:
        return '还没有评价';
    }
  }

  String _emptyReviewSubtitle() {
    switch (_reviewFilter) {
      case 'with_image':
        return '等同学上传真实图片后就能看到啦';
      case 'high':
        return '也许还没有同学给出 4 分以上评价';
      case 'low':
        return '目前还没有明显踩雷反馈';
      default:
        return '快来成为第一个评价的同学吧';
    }
  }

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

  Widget _stars(double avg, double size) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
          5,
          (i) => Icon(
            i < avg.round() ? Icons.star : Icons.star_border,
            size: size,
            color: i < avg.round() ? Colors.amber : Colors.grey[400],
          ),
        ),
      );

  void _showRatingDialog() {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后评价')));
      return;
    }

    final myRating = _canteenData!['my_rating'];
    if (myRating != null) {
      _star = myRating['star'] ?? 0;
      _commentCtrl.text = myRating['comment'] ?? '';
      _ratingImages = [];
      try {
        if (myRating['images'] != null &&
            myRating['images'].toString().startsWith('[')) {
          final decoded = myRating['images'].toString();
          _ratingImages = decoded
              .substring(1, decoded.length - 1)
              .split(',')
              .map((e) => e.replaceAll('"', '').trim())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } catch (e) {
        // ignore parsing error
      }
    } else {
      _star = 0;
      _commentCtrl.text = '';
      _ratingImages = [];
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '我的评价',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      5,
                      (i) => GestureDetector(
                        onTap: () => setModalState(() => _star = i + 1),
                        child: Icon(
                          i < _star ? Icons.star : Icons.star_border,
                          size: 36,
                          color: i < _star ? Colors.amber : Colors.grey[400],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _commentCtrl,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      hintText: '说说感受...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  ImageUploadWidget(
                    maxImages: 9,
                    onImagesUploaded: (urls) {
                      _ratingImages = urls;
                    },
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: _star == 0
                            ? null
                            : () async {
                                final result = await context
                                    .read<CanteenProvider>()
                                    .rateCanteen(
                                      widget.canteenId,
                                      _star,
                                      _commentCtrl.text,
                                      _ratingImages,
                                    );
                                if (!context.mounted) return;
                                if (result) {
                                  Navigator.pop(ctx);
                                  _loadData();
                                }
                              },
                        child: Text(myRating == null ? '提交' : '更新'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showEditImageSheet() {
    List<String> uploadedImages = [];
    final currentImage = _canteenData!['canteen']['image'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '修改食堂封面图',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text('当前图片：', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 8),
              if (currentImage != null && currentImage.toString().isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: ApiConstants.fullUrl(currentImage),
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(height: 16),
              const Text('上传新图片：', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 8),
              ImageUploadWidget(
                maxImages: 1,
                onImagesUploaded: (urls) {
                  uploadedImages = urls;
                },
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        if (uploadedImages.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请先上传图片')),
                          );
                          return;
                        }
                        final newUrl = uploadedImages.first;
                        final messenger = ScaffoldMessenger.of(context);
                        final result = await context
                            .read<CanteenProvider>()
                            .updateCanteenImage(widget.canteenId, newUrl);
                        if (result != null) {
                          if (!context.mounted || !ctx.mounted) return;
                          Navigator.pop(ctx);
                          messenger.showSnackBar(
                            const SnackBar(content: Text('食堂图片已更新')),
                          );
                          setState(() {
                            _canteenData!['canteen'] = result;
                          });
                        } else {
                          if (!context.mounted || !ctx.mounted) return;
                          messenger.showSnackBar(
                            const SnackBar(content: Text('更新失败')),
                          );
                        }
                      },
                      child: const Text('保存图片'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}
