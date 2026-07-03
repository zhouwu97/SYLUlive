import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/teacher_provider.dart';
import '../providers/theme_provider.dart';
import '../models/teacher.dart';
import '../widgets/rating_detail/rating_subject_header.dart';
import '../widgets/rating_detail/rating_score_panel.dart';
import '../widgets/rating_detail/my_rating_card.dart';
import '../widgets/rating_detail/rating_item_card.dart';
import '../widgets/rating_detail/rating_policy_tip.dart';
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

  @override
  void dispose() {
    super.dispose();
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

    return PopScope(
      canPop: themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _didChange);
      },
      child: Scaffold(
        backgroundColor:
            isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
        extendBodyBehindAppBar: false, // 修复重叠：不再将 body 延伸到 AppBar 后方
        appBar: AppBar(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(
            color: isDark ? Colors.white : Colors.black87,
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _didChange),
          ),
          title: const Text('教师评价'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            if (context.watch<AuthProvider>().user?.isAdmin == true)
              PopupMenuButton<String>(
                icon: Icon(Icons.more_horiz, color: isDark ? Colors.white : Colors.black87),
                onSelected: (value) {
                  if (value == 'delete') _deleteTeacher(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('删除教师'),
                  ),
                ],
              ),
          ],
        ),
        body: Consumer<TeacherProvider>(
          builder: (context, provider, _) {
            if (provider.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            final teacher = provider.selectedTeacher;
            if (teacher == null) return const Center(child: Text('加载失败'));

            return Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 84),
                  children: [
                    RatingSubjectHeader(
                      title: teacher.name,
                      subtitle: teacher.course,
                      initial: teacher.name,
                    ),
                    const SizedBox(height: 8),
                    RatingScorePanel(
                      averageStar: provider.averageStar,
                      ratingCount: provider.ratingCount,
                      starCounts: provider.starCounts,
                    ),
                    const SizedBox(height: 10),
                    if (provider.myRating != null) ...[
                      MyRatingCard(
                        currentStar: provider.myRating!.star,
                        currentComment: provider.myRating!.comment,
                        isDeleting: _isDeletingRating,
                        onEdit: () {
                          showRatingInputSheet(
                            context: context,
                            initialStar: provider.myRating!.star,
                            initialComment: provider.myRating!.comment ?? '',
                            title: '修改评价',
                            maxCommentLength: 200,
                            onSubmit: (star, comment) async {
                              final ok = await provider.rateTeacher(widget.teacherId, star, comment);
                              if (ok) {
                                _didChange = true;
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('评价修改成功'), backgroundColor: Colors.green),
                                  );
                                }
                              }
                              return ok;
                            },
                          );
                        },
                        onDelete: () => _confirmDeleteRating(provider.myRating!),
                      ),
                      const SizedBox(height: 10),
                    ],
                    _buildRatingSection(provider, isDark),
                    const SizedBox(height: 80),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: RatingBottomInputBar(
                    hintText: '写下你的课堂体验...',
                    onTap: () {
                      if (!context.read<AuthProvider>().isLoggedIn) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请先登录后评价')),
                        );
                        return;
                      }
                      showRatingInputSheet(
                        context: context,
                        initialStar: provider.myRating?.star ?? 0,
                        initialComment: provider.myRating?.comment ?? '',
                        title: provider.myRating == null ? '写评价' : '修改评价',
                        maxCommentLength: 200,
                        onSubmit: (star, comment) async {
                          final ok = await provider.rateTeacher(widget.teacherId, star, comment);
                          if (ok) {
                            _didChange = true;
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('评价成功'), backgroundColor: Colors.green),
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

  Widget _buildRatingSection(TeacherProvider provider, bool isDark) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '全部评价 / ${provider.ratingCount}',
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
          type: RatingPolicyType.warning,
          text: '请只评价课堂体验，避免人身攻击和隐私信息。',
        ),
        if (provider.ratings.isEmpty)
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
              children: provider.ratings.map((r) => RatingItemCard(
                userName: r.userName,
                comment: r.comment,
                star: r.star,
                isOwn: _isOwnRating(r),
                onLongPress: () => _confirmDeleteRating(r),
              )).toList(),
            ),
          ),
      ],
    ),
    );
  }
}
