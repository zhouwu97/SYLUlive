import 'dart:io' show File;

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

  const TeacherDetailScreen(
      {super.key, required this.teacherId, required this.teacherName});

  @override
  State<TeacherDetailScreen> createState() => _TeacherDetailScreenState();
}

class _TeacherDetailScreenState extends State<TeacherDetailScreen> {
  final _commentCtrl = TextEditingController();
  int _star = 0;
  bool _isEditing = false;
  bool _didChange = false;

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除教师「${widget.teacherName}」吗？此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
      final dio = context.read<AuthProvider>().dio;
      await dio.delete('/teachers/${widget.teacherId}/reject');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('教师已删除')));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _didChange);
        return false;
      },
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF131720) : Colors.white,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
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
        body: Stack(
          children: [
            Positioned.fill(child: _buildBackground(themeProvider, isDark)),
            Consumer<TeacherProvider>(
              builder: (context, provider, _) {
                if (provider.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }

                final teacher = provider.selectedTeacher;
                if (teacher == null) return const Center(child: Text('加载失败'));

                return SafeArea(
                  child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                  children: [
                    _buildHeader(teacher, provider, isDark),
                    const SizedBox(height: 16),
                    _buildMyRating(provider, isDark),
                    const SizedBox(height: 20),
                    if (provider.ratings.isNotEmpty) ...[
                      Text('${provider.ratingCount}人评价',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87)),
                      const SizedBox(height: 8),
                      ...provider.ratings
                          .map((r) => _buildRatingCard(r, isDark)),
                    ],
                    const SizedBox(height: 80),
                  ],
                ),
              );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset('assets/images/$bgPath', fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark))
              : bgPath.startsWith('/')
                  ? Image.file(File(bgPath), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark))
                  : Image.network(bgPath, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark)),
          Container(color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.25)),
        ],
      );
    }
    return _buildDefaultBackground(isDark);
  }

  Widget _buildDefaultBackground(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: ResizeImage(
            const AssetImage('assets/images/morenbeijing.jpeg'),
            width: 1080,
          ),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: isDark ? const Color(0xFF0F131A) : const Color(0xFFF5F7FB),
          ),
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  Widget _buildHeader(Teacher teacher, TeacherProvider provider, bool isDark) {
    return GlassContainer(
      borderRadius: 16,
      blur: 12,
      opacity: 0.16,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            CircleAvatar(
                radius: 36,
                backgroundColor: const Color(0xFF6366F1),
                child: Text(teacher.name.isNotEmpty ? teacher.name[0] : '?',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold))),
            const SizedBox(height: 12),
            Text(teacher.name,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(teacher.course,
                style: TextStyle(fontSize: 15, color: Colors.grey[600])),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _buildStarRowLarge(provider.averageStar),
              const SizedBox(width: 8),
              Text(
                  '${provider.averageStar.toStringAsFixed(1)} (${provider.ratingCount}人)',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ]),
          ],
        ),
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
        backgroundColor:
            isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
        child: const Padding(
            padding: EdgeInsets.all(16), child: Center(child: Text('请先登录后评价'))),
      );
    }

    return GlassContainer(
      borderRadius: 12,
      blur: 12,
      opacity: 0.16,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('我的评价',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87)),
              const Spacer(),
              if (provider.myRating != null && !_isEditing)
                TextButton(
                    onPressed: () {
                      setState(() {
                        _isEditing = true;
                        _star = provider.myRating!.star;
                        _commentCtrl.text = provider.myRating!.comment;
                      });
                    },
                    child: const Text('修改')),
            ]),
            const SizedBox(height: 8),
            if (!_isEditing && provider.myRating != null) ...[
              _buildStarRowLarge(provider.myRating!.star.toDouble()),
              if (provider.myRating!.comment.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(provider.myRating!.comment,
                    style: TextStyle(
                        color: isDark ? Colors.grey[300] : Colors.grey[700])),
              ],
            ] else ...[
              // 评分星星
              Row(
                  children: List.generate(
                      5,
                      (i) => GestureDetector(
                            onTap: () => setState(() => _star = i + 1),
                            child: Icon(
                                i < _star ? Icons.star : Icons.star_border,
                                size: 36,
                                color: i < _star
                                    ? Colors.amber
                                    : Colors.grey[400]),
                          ))),
              const SizedBox(height: 8),
              // 评论输入
              TextField(
                controller: _commentCtrl,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: '说说你的感受...',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              // 提交按钮
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (_isEditing)
                  TextButton(
                      onPressed: () => setState(() => _isEditing = false),
                      child: const Text('取消')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _star == 0
                      ? null
                      : () async {
                          final ok = await provider.rateTeacher(
                              widget.teacherId, _star, _commentCtrl.text);
                          if (ok && mounted) {
                            _didChange = true;
                            setState(() => _isEditing = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('评价成功'),
                                  backgroundColor: Colors.green),
                            );
                          }
                        },
                  child: Text(_isEditing ? '更新' : '提交评价'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRatingCard(TeacherRating r, bool isDark) {
    final auth = context.watch<AuthProvider>();
    final isOwn = auth.user?.id == r.userId;

    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 8),
      borderRadius: 10,
      blur: 10,
      opacity: 0.14,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                  radius: 14,
                  backgroundColor: const Color(0xFF6366F1),
                  child: Text(r.userName.isNotEmpty ? r.userName[0] : '?',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12))),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(r.userName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14))),
              _buildStarRowSmall(r.star.toDouble()),
              if (isOwn)
                GestureDetector(
                  onTap: () => _confirmDelete(r.id),
                  child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.delete_outline,
                          size: 18, color: Colors.red)),
                )
              else
                GestureDetector(
                  onTap: () => _reportRating(r.id),
                  child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.flag_outlined,
                          size: 18, color: Colors.grey)),
                ),
            ]),
            if (r.comment.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(r.comment,
                  style: TextStyle(
                      color: isDark ? Colors.grey[300] : Colors.grey[700],
                      fontSize: 14)),
            ],
          ],
        ),
      ),
    );
  }

  void _confirmDelete(int ratingId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除评价'),
        content: const Text('确定要删除你的评价吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await context
                  .read<TeacherProvider>()
                  .deleteRating(ratingId, widget.teacherId);
              if (mounted) {
                if (ok) _didChange = true;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(ok ? '已删除' : '删除失败'),
                      backgroundColor: ok ? Colors.green : Colors.red),
                );
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _reportRating(int ratingId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('举报评价'),
        content: const Text('确定要举报这条评价吗？管理员将审核处理。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ok =
                  await context.read<TeacherProvider>().reportRating(ratingId);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(ok ? '举报已提交' : '举报失败'),
                      backgroundColor: ok ? Colors.green : Colors.red),
                );
              }
            },
            child: const Text('确认举报'),
          ),
        ],
      ),
    );
  }

  Widget _buildStarRowLarge(double avg) {
    return Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) {
          return Icon(i < avg.round() ? Icons.star : Icons.star_border,
              size: 28,
              color: i < avg.round() ? Colors.amber : Colors.grey[350]);
        }));
  }

  Widget _buildStarRowSmall(double avg) {
    return Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) {
          return Icon(i < avg.round() ? Icons.star : Icons.star_border,
              size: 14,
              color: i < avg.round() ? Colors.amber : Colors.grey[400]);
        }));
  }
}
