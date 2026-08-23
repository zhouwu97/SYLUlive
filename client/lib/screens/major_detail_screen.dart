import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/major_provider.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import '../widgets/rating_detail/rating_subject_header.dart';
import '../widgets/rating_detail/rating_report_sheet.dart';
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
    final accent = RankingTokens.majorAccent(isDark);

    return Scaffold(
      backgroundColor: RankingTokens.pageBg(isDark),
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        ),
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: RankingTokens.titleColor(isDark),
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
        iconTheme: IconThemeData(color: RankingTokens.titleColor(isDark)),
        title: const Text('专业评价'),
        backgroundColor: RankingTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (context.watch<AuthProvider>().user?.isAdmin == true)
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_horiz,
                color: RankingTokens.titleColor(isDark),
              ),
              onSelected: (value) {
                if (value == 'delete') _deleteMajor();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('删除专业')),
              ],
            ),
        ],
      ),
      body: Consumer<MajorProvider>(
        builder: (_, m, __) {
          if (m.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (m.selectedMajorId != widget.majorId || m.selected == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(m.errorMessage ?? '专业信息加载失败'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => m.loadDetail(widget.majorId),
                    child: const Text('重新加载'),
                  ),
                ],
              ),
            );
          }
          return Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 80),
                children: [
                  RatingSubjectHeader(
                    title: m.selected!.name,
                    subtitle: m.selected!.level,
                    initial: m.selected!.name,
                    accentOverride: accent,
                  ),
                  const SizedBox(height: 8),
                  RatingScorePanel(
                    averageStar: m.averageStar,
                    ratingCount: m.ratingCount,
                    starCounts: m.starCounts,
                    accentOverride: accent,
                  ),
                  const SizedBox(height: 10),
                  if (m.myRating != null) ...[
                    MyRatingCard(
                      currentStar: m.myRating!.star,
                      currentComment: m.myRating!.comment,
                      isDeleting: _isDeletingRating,
                      accentOverride: accent,
                      onEdit: () {
                        showRatingInputSheet(
                          context: context,
                          initialStar: m.myRating!.star,
                          initialComment: m.myRating!.comment,
                          title: '修改评价',
                          maxCommentLength: 500,
                          accentOverride: accent,
                          onSubmit: (star, comment) async {
                            final messenger = ScaffoldMessenger.of(context);
                            final ok = await m.rate(
                              widget.majorId,
                              star,
                              comment,
                            );
                            if (ok && mounted) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('评价修改成功'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            } else if (!ok && mounted) {
                              messenger.showSnackBar(
                                const SnackBar(content: Text('评价修改失败，请稍后重试')),
                              );
                            }
                            return ok;
                          },
                        );
                      },
                      onDelete: () => _confirmDeleteRating(m.myRating!),
                    ),
                    const SizedBox(height: 10),
                  ],
                  _buildRatingSection(m, isDark, accent),
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
                      accentOverride: accent,
                      onSubmit: (star, comment) async {
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await m.rate(
                          widget.majorId,
                          star,
                          comment,
                        );
                        if (ok && mounted) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('评价成功'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        } else if (!ok && mounted) {
                          messenger.showSnackBar(
                            const SnackBar(content: Text('评价失败，请稍后重试')),
                          );
                        }
                        return ok;
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

  Widget _buildRatingSection(MajorProvider m, bool isDark, Color accent) {
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
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const RatingPolicyTip(
            type: RatingPolicyType.info,
            text: '评价请基于课程设置、培养方案、学习体验和就业方向，避免攻击个人或群体。',
          ),
          if (m.ratings.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 20, bottom: 20),
              child: Center(
                child: Text(
                  '还没有同学评价',
                  style: TextStyle(
                    fontSize: 13,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
              ),
            )
          else
            Column(
              children: [
                ...m.ratings.map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: RatingItemCard(
                        userName: r.userName,
                        userAvatar: r.userAvatar,
                        comment: r.comment,
                        star: r.star,
                        isOwn: _isOwnRating(r),
                        createdAt: r.createdAt,
                        updatedAt: r.updatedAt,
                        helpfulCount: r.helpfulCount,
                        unhelpfulCount: r.unhelpfulCount,
                        myVote: r.myVote,
                        onHelpful: () => m.voteRating(r.id, 'up'),
                        onUnhelpful: () => m.voteRating(r.id, 'down'),
                        onReport: () {
                          showRatingReportSheet(
                            context: context,
                            targetType: 'major_rating',
                            targetId: r.id,
                            onSubmit: (code, desc) async {
                              final success = await m.reportRating(
                                r.id,
                                code,
                                desc,
                              );
                              if (success && mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('举报已提交，我们会尽快处理')),
                                );
                              } else if (!success && mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('举报失败或已提交过')),
                                );
                              }
                              return success;
                            },
                          );
                        },
                        onEdit: _isOwnRating(r)
                            ? () {
                                showRatingInputSheet(
                                  context: context,
                                  initialStar: r.star,
                                  initialComment: r.comment,
                                  title: '修改评价',
                                  maxCommentLength: 500,
                                  accentOverride: accent,
                                  onSubmit: (star, comment) async {
                                    final ok = await m.rate(
                                        widget.majorId, star, comment);
                                    return ok;
                                  },
                                );
                              }
                            : null,
                        onDelete: _isOwnRating(r)
                            ? () => _confirmDeleteRating(r)
                            : null,
                      ),
                    )),
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 10),
                  child: Center(
                    child: Text(
                      '更多评价等待同学补充',
                      style: TextStyle(
                        fontSize: 12,
                        color: RankingTokens.subColor(isDark),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
