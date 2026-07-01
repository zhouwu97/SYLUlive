import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/teacher_provider.dart';
import '../providers/theme_provider.dart';
import '../models/teacher.dart';
import '../widgets/glass_container.dart';

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
  final _commentCtrl = TextEditingController();
  int _star = 0;
  bool _isEditing = false;
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
    _commentCtrl.dispose();
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
        _isEditing = false;
        _star = 0;
        _commentCtrl.clear();
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
          title: Text(widget.teacherName),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            if (context.watch<AuthProvider>().user?.isAdmin == true)
              IconButton(
                icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                onPressed: () => _deleteTeacher(context),
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

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
              children: [
                _buildHeader(teacher, provider, isDark),
                const SizedBox(height: 12),
                _buildMyRating(provider, isDark),
                const SizedBox(height: 18),
                _buildRatingSection(provider, isDark),
                const SizedBox(height: 80),
              ],
            );
          },
        ),
      ),
    );
  }

  Color _surfaceColor(bool isDark) =>
      isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF);

  Color _mutedTextColor(bool isDark) =>
      isDark ? Colors.grey.shade300 : Colors.grey.shade600;

  String _initial(String text) {
    final value = text.trim();
    return value.isEmpty ? '?' : value[0];
  }

  Widget _buildHeader(Teacher teacher, TeacherProvider provider, bool isDark) {
    return GlassContainer(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      borderRadius: 18,
      blur: 12,
      opacity: 0.16,
      backgroundColor: _surfaceColor(isDark),
      child: Column(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: const Color(0xFF6366F1),
            child: Text(
              _initial(teacher.name),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 27,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            teacher.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 21,
              height: 1.18,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            teacher.course,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: _mutedTextColor(isDark)),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: isDark ? 0.12 : 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildStarRowLarge(provider.averageStar),
                const SizedBox(width: 8),
                Text(
                  '${provider.averageStar.toStringAsFixed(1)} (${provider.ratingCount}人)',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyRating(TeacherProvider provider, bool isDark) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isLoggedIn) {
      return GlassContainer(
        borderRadius: 12,
        blur: 12,
        opacity: 0.16,
        backgroundColor: _surfaceColor(isDark),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: Text('请先登录后评价')),
        ),
      );
    }

    return GlassContainer(
      onLongPress: provider.myRating != null && !_isEditing
          ? () => _confirmDeleteRating(provider.myRating!)
          : null,
      padding: const EdgeInsets.all(16),
      borderRadius: 14,
      blur: 12,
      opacity: 0.16,
      backgroundColor: _surfaceColor(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '我的评价',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              if (!_isEditing)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isEditing = true;
                      _star = provider.myRating?.star ?? 0;
                      _commentCtrl.text = provider.myRating?.comment ?? '';
                    });
                  },
                  child: Text(provider.myRating == null ? '打分' : '修改'),
                ),
            ],
          ),
          if (!_isEditing && provider.myRating != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _buildStarRowLarge(provider.myRating!.star.toDouble()),
                const SizedBox(width: 10),
                Text(
                  '${provider.myRating!.star}.0分',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (provider.myRating!.comment.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  provider.myRating!.comment.trim(),
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: _mutedTextColor(isDark),
                  ),
                ),
              ),
          ] else if (!_isEditing) ...[
            const SizedBox(height: 6),
            Text(
              '点击右侧按钮进行评价',
              style: TextStyle(fontSize: 13, color: _mutedTextColor(isDark)),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Row(
              children: List.generate(
                5,
                (i) => GestureDetector(
                  onTap: () => setState(() => _star = i + 1),
                  child: Icon(
                    i < _star ? Icons.star : Icons.star_border,
                    size: 34,
                    color: i < _star ? Colors.amber : Colors.grey[400],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _commentCtrl,
              maxLines: 3,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: '写下对老师的评价（选填）',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor:
                    isDark ? const Color(0x33FFFFFF) : const Color(0x0A000000),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _isEditing = false;
                    _star = provider.myRating?.star ?? 0;
                    _commentCtrl.text = provider.myRating?.comment ?? '';
                  }),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _star == 0
                      ? null
                      : () async {
                          final ok = await provider.rateTeacher(
                            widget.teacherId,
                            _star,
                            _commentCtrl.text.trim(),
                          );
                          if (ok && mounted) {
                            _didChange = true;
                            setState(() => _isEditing = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('评价成功'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          }
                        },
                  child: Text(provider.myRating == null ? '提交' : '更新'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRatingSection(TeacherProvider provider, bool isDark) {
    if (provider.ratings.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${provider.ratingCount}人评价',
              style: TextStyle(
                fontSize: 16,
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
              ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: isDark ? 0.14 : 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.orange.withValues(alpha: isDark ? 0.28 : 0.18),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange[700],
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '禁止对老师造成人格侮辱，只准对课堂行为评价。',
                  style: TextStyle(
                    fontSize: 13,
                    color: _mutedTextColor(isDark),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ...provider.ratings.map((r) => _buildRatingCard(r, isDark)),
      ],
    );
  }

  Widget _buildRatingCard(TeacherRating r, bool isDark) {
    final isOwn = _isOwnRating(r);
    final comment = r.comment.trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: isDark ? const Color(0xFF1C2230) : Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onLongPress: isOwn ? () => _confirmDeleteRating(r) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFF6366F1),
                child: Text(
                  _initial(r.userName),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            r.userName.trim().isNotEmpty
                                ? r.userName.trim()
                                : '匿名',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                        if (isOwn) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF6366F1,
                              ).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '我的',
                              style: TextStyle(
                                color: Color(0xFF6366F1),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (comment.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(
                          comment,
                          style: TextStyle(
                            color: _mutedTextColor(isDark),
                            fontSize: 14,
                            height: 1.42,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildStarRowSmall(r.star.toDouble()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStarRowLarge(double avg) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < avg.round() ? Icons.star : Icons.star_border,
          size: 28,
          color: i < avg.round() ? Colors.amber : Colors.grey[350],
        );
      }),
    );
  }

  Widget _buildStarRowSmall(double avg) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < avg.round() ? Icons.star : Icons.star_border,
          size: 14,
          color: i < avg.round() ? Colors.amber : Colors.grey[400],
        );
      }),
    );
  }
}
