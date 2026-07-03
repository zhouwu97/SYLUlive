import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/major_provider.dart';
import '../widgets/rating_detail/rating_subject_header.dart';
import '../widgets/rating_detail/rating_score_panel.dart';
import '../widgets/rating_detail/my_rating_card.dart';
import '../widgets/rating_detail/rating_item_card.dart';
import '../widgets/rating_detail/rating_policy_tip.dart';
import '../widgets/rating_detail/rating_bottom_input_bar.dart';
import '../widgets/rating_detail/rating_input_sheet.dart';
class MajorDetailScreen extends StatefulWidget {
  final int majorId;
  final String majorName;
  const MajorDetailScreen({
    super.key,
    required this.majorId,
    required this.majorName,
  });
  @override
  State<MajorDetailScreen> createState() => _MajorDetailScreenState();
}

class _MajorDetailScreenState extends State<MajorDetailScreen> {
  bool _isDeletingRating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MajorProvider>().loadDetail(widget.majorId);
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  bool _isOwnRating(MajorRating rating) {
    final userId = context.read<AuthProvider>().user?.id;
    return userId != null && userId == rating.userId;
  }

  Future<void> _confirmDeleteRating(MajorRating rating) async {
    if (!_isOwnRating(rating) || _isDeletingRating) return;

    final provider = context.read<MajorProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除评价'),
        content: const Text('确定删除自己的这条评价吗？删除后评分会重新计算。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeletingRating = true);
    final ok = await provider.deleteRating(rating.id, widget.majorId);
    if (!mounted) return;

    setState(() {
      _isDeletingRating = false;
    });

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? '评价已删除' : '删除失败，请稍后再试'),
        backgroundColor: ok ? Colors.green : Colors.redAccent,
      ),
    );
  }

  Future<void> _deleteMajor() async {
    final provider = context.read<MajorProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除专业'),
        content: const Text('确定要删除这个专业吗？删除后该专业下的所有评分也将一并清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final success = await provider.deleteMajor(widget.majorId);
    if (!mounted) return;

    if (success) {
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('已删除专业')));
    } else {
      messenger.showSnackBar(const SnackBar(content: Text('删除失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      extendBodyBehindAppBar: false, // 修复重叠
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        ),
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black87),
        title: const Text('专业评价'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (context.watch<AuthProvider>().user?.isAdmin == true)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, color: isDark ? Colors.white : Colors.black87),
              onSelected: (value) {
                if (value == 'delete') _deleteMajor();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: Text('删除专业'),
                ),
              ],
            ),
        ],
      ),
      body: Consumer<MajorProvider>(
        builder: (_, m, __) {
          if (m.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (m.selected == null) return const Center(child: Text('加载失败'));
          return Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 84),
                children: [
                  RatingSubjectHeader(
                    title: m.selected!.name,
                    subtitle: m.selected!.level,
                    initial: m.selected!.name,
                  ),
                  const SizedBox(height: 8),
                  RatingScorePanel(
                    averageStar: m.averageStar,
                    ratingCount: m.ratingCount,
                    starCounts: m.starCounts,
                  ),
                  const SizedBox(height: 10),
                  if (m.myRating != null) ...[
                    MyRatingCard(
                      currentStar: m.myRating!.star,
                      currentComment: m.myRating!.comment,
                      isDeleting: _isDeletingRating,
                      onEdit: () {
                        showRatingInputSheet(
                          context: context,
                          initialStar: m.myRating!.star,
                          initialComment: m.myRating!.comment ?? '',
                          title: '修改评价',
                          maxCommentLength: 500,
                          onSubmit: (star, comment) async {
                            try {
                              await m.rate(widget.majorId, star, comment);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('评价修改成功'), backgroundColor: Colors.green),
                                );
                              }
                              return true;
                            } catch (e) {
                              return false;
                            }
                          },
                        );
                      },
                      onDelete: () => _confirmDeleteRating(m.myRating!),
                    ),
                    const SizedBox(height: 10),
                  ],
                  _buildRatingSection(m, isDark),
                  const SizedBox(height: 80),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: RatingBottomInputBar(
                  hintText: '写下你对这个专业的看法...',
                  onTap: () {
                    if (!context.read<AuthProvider>().isLoggedIn) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请先登录后评价')),
                      );
                      return;
                    }
                    showRatingInputSheet(
                      context: context,
                      initialStar: m.myRating?.star ?? 0,
                      initialComment: m.myRating?.comment ?? '',
                      title: m.myRating == null ? '写评价' : '修改评价',
                      maxCommentLength: 500,
                      onSubmit: (star, comment) async {
                        try {
                          await m.rate(widget.majorId, star, comment);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('评价成功'), backgroundColor: Colors.green),
                            );
                          }
                          return true;
                        } catch (e) {
                          return false;
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRatingSection(MajorProvider m, bool isDark) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '全部评价 / ${m.ratingCount}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              if (_isDeletingRating)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  '最新',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
        const RatingPolicyTip(
          type: RatingPolicyType.info,
          text: '评价请基于课程设置、培养方案、学习体验和就业方向，避免攻击个人或群体。',
        ),
        if (m.ratings.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 24),
            child: Center(
              child: Text(
                '还没有同学评价',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.grey.shade300 : Colors.grey.shade600,
                ),
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1B1E28) : Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                ...m.ratings.map((r) => RatingItemCard(
                  userName: r.userName,
                  comment: r.comment,
                  star: r.star,
                  isOwn: _isOwnRating(r),
                  onLongPress: () => _confirmDeleteRating(r),
                )),
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 12),
                  child: Center(
                    child: Text(
                      '更多评价等待同学补充',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
    );
  }
}
