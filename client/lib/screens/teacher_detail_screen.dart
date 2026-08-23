import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/teacher.dart';
import '../providers/auth_provider.dart';
import '../providers/teacher_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import '../widgets/rating_detail/rating_subject_header.dart';
import '../widgets/rating_detail/rating_score_panel.dart';
import '../widgets/rating_detail/my_rating_card.dart';
import '../widgets/rating_detail/teacher_rating_item_card.dart';
import '../widgets/rating_detail/rating_policy_tip.dart';
import '../widgets/rating_detail/rating_report_sheet.dart';
import '../widgets/rating_detail/rating_bottom_input_bar.dart';
import '../widgets/rating_detail/rating_input_sheet.dart';

class TeacherDetailScreen extends StatefulWidget {
  final int teacherId;
  final String teacherName;

  const TeacherDetailScreen({
    super.key,
    required this.teacherId,
    required this.teacherName,
  });

  @override
  State<TeacherDetailScreen> createState() => _TeacherDetailScreenState();
}

class _TeacherDetailScreenState extends State<TeacherDetailScreen> {
  bool _didChange = false;
  bool _isDeletingRating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TeacherProvider>().loadTeacherDetail(widget.teacherId);
    });
  }

  Future<void> _deleteTeacher(BuildContext context) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除教师「${widget.teacherName}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await dio.delete('/teachers/${widget.teacherId}/reject');
      if (mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('教师已删除')));
        navigator.pop(true);
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  bool _isOwnRating(TeacherRating rating) {
    final userId = context.read<AuthProvider>().user?.id;
    return userId != null && userId == rating.userId;
  }

  Future<void> _confirmDeleteRating(TeacherRating rating) async {
    if (!_isOwnRating(rating) || _isDeletingRating) return;

    final provider = context.read<TeacherProvider>();
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
    final ok = await provider.deleteRating(rating.id, widget.teacherId);
    if (!mounted) return;

    setState(() {
      _isDeletingRating = false;
      if (ok) {
        _didChange = true;
      }
    });

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? '评价已删除' : '删除失败，请稍后再试'),
        backgroundColor: ok ? Colors.green : Colors.redAccent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final accent = RankingTokens.teacherAccent(isDark);

    return PopScope(
      canPop: themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _didChange);
      },
      child: Scaffold(
        backgroundColor: RankingTokens.pageBg(isDark),
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: RankingTokens.titleColor(isDark),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
          iconTheme: IconThemeData(color: RankingTokens.titleColor(isDark)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _didChange),
          ),
          title: const Text('教师评价'),
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
                  if (value == 'delete') _deleteTeacher(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除教师')),
                ],
              ),
          ],
        ),
        body: Consumer<TeacherProvider>(
          builder: (context, provider, _) {
            final detail = provider.detailOf(widget.teacherId);
            if (detail.isLoading && detail.teacher == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final teacher = detail.teacher;
            if (teacher == null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(detail.errorMessage ?? '教师信息加载失败'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        provider.loadTeacherDetail(
                          widget.teacherId,
                          force: true,
                        );
                      },
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
                      title: teacher.name,
                      subtitle: teacher.course,
                      initial: teacher.name,
                      accentOverride: accent,
                      showInitialBadge: false,
                    ),
                    const SizedBox(height: 8),
                    RatingScorePanel(
                      averageStar: detail.averageStar,
                      ratingCount: detail.ratingCount,
                      starCounts: detail.starCounts,
                      accentOverride: accent,
                    ),
                    const SizedBox(height: 10),
                    if (detail.myRating != null) ...[
                      MyRatingCard(
                        currentStar: detail.myRating!.star,
                        currentComment: detail.myRating!.comment,
                        isDeleting: _isDeletingRating,
                        accentOverride: accent,
                        onEdit: () {
                          showRatingInputSheet(
                            context: context,
                            initialStar: detail.myRating!.star,
                            initialComment: detail.myRating!.comment,
                            title: '修改评价',
                            maxCommentLength: 200,
                            accentOverride: accent,
                            onSubmit: (star, comment) async {
                              final ok = await provider.rateTeacher(
                                  widget.teacherId, star, comment);
                              if (ok) {
                                _didChange = true;
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('评价修改成功'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              }
                              return ok;
                            },
                          );
                        },
                        onDelete: () => _confirmDeleteRating(detail.myRating!),
                      ),
                      const SizedBox(height: 10),
                    ],
                    _buildRatingSection(provider, detail, isDark, accent),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: RatingBottomInputBar(
                    hintText: '写下你的课堂体验...',
                    accentOverride: accent,
                    onTap: () {
                      if (!context.read<AuthProvider>().isLoggedIn) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先登录后评价')),
                        );
                        return;
                      }
                      showRatingInputSheet(
                        context: context,
                        initialStar: detail.myRating?.star ?? 0,
                        initialComment: detail.myRating?.comment ?? '',
                        title: detail.myRating == null ? '写评价' : '修改评价',
                        maxCommentLength: 200,
                        accentOverride: accent,
                        onSubmit: (star, comment) async {
                          final ok = await provider.rateTeacher(
                              widget.teacherId, star, comment);
                          if (ok) {
                            _didChange = true;
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('评价成功'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
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
      ),
    );
  }

  Widget _buildRatingSection(
    TeacherProvider provider,
    TeacherDetailState detail,
    bool isDark,
    Color accent,
  ) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '全部评价 / ${detail.ratingCount}',
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
            type: RatingPolicyType.warning,
            text: '请只评价课堂体验，避免人身攻击和隐私信息。',
          ),
          if (detail.ratings.isEmpty)
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
              children: detail.ratings
                  .map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TeacherRatingItemCard(
                          userName: r.userName,
                          userAvatar: r.userAvatar,
                          comment: r.comment,
                          star: r.star,
                          accent: accent,
                          isOwn: _isOwnRating(r),
                          createdAt: r.createdAt,
                          updatedAt: r.updatedAt,
                          helpfulCount: r.helpfulCount,
                          unhelpfulCount: r.unhelpfulCount,
                          myVote: r.myVote,
                          onHelpful: () =>
                              provider.voteRating(r.id, widget.teacherId, 'up'),
                          onUnhelpful: () => provider.voteRating(
                              r.id, widget.teacherId, 'down'),
                          onReport: () {
                            showRatingReportSheet(
                              context: context,
                              targetType: 'teacher_rating',
                              targetId: r.id,
                              onSubmit: (code, desc) async {
                                final success = await provider.reportRating(
                                  r.id,
                                  widget.teacherId,
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
                                    maxCommentLength: 200,
                                    accentOverride: accent,
                                    onSubmit: (star, comment) async {
                                      final ok = await provider.rateTeacher(
                                          widget.teacherId, star, comment);
                                      if (ok) {
                                        _didChange = true;
                                      }
                                      return ok;
                                    },
                                  );
                                }
                              : null,
                          onDelete: _isOwnRating(r)
                              ? () => _confirmDeleteRating(r)
                              : null,
                        ),
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }
}
