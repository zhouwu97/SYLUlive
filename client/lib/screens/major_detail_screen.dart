import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/major_provider.dart';
import '../providers/theme_provider.dart';

class MajorDetailScreen extends StatefulWidget {
  final int majorId;
  final String majorName;
  const MajorDetailScreen(
      {super.key, required this.majorId, required this.majorName});
  @override
  State<MajorDetailScreen> createState() => _MajorDetailScreenState();
}

class _MajorDetailScreenState extends State<MajorDetailScreen> {
  final _commentCtrl = TextEditingController();
  int _star = 0;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MajorProvider>().loadDetail(widget.majorId);
    });
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

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
        iconTheme: IconThemeData(
          color: isDark ? Colors.white : Colors.black87,
        ),
        title: Text(widget.majorName),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (context.watch<AuthProvider>().user?.isAdmin == true)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除专业'),
                    content: const Text('确定要删除这个专业吗？删除后该专业下的所有评分也将一并清除。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('删除',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (confirm == true) {
                  final success = await context
                      .read<MajorProvider>()
                      .deleteMajor(widget.majorId);
                  if (success && mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已删除专业')));
                  } else if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('删除失败')));
                  }
                }
              },
            ),
        ],
      ),
      body: Consumer<MajorProvider>(
        builder: (_, m, __) {
          if (m.isLoading)
            return const Center(child: CircularProgressIndicator());
          if (m.selected == null) return const Center(child: Text('加载失败'));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 80), // 顶部边距设为 0
            children: [
              Card(
                color: isDark ? Colors.grey[850] : Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    CircleAvatar(
                        radius: 36,
                        backgroundColor: const Color(0xFF6366F1),
                        child: Text(m.selected!.name[0],
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold))),
                    const SizedBox(height: 12),
                    Text(m.selected!.name,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold)),
                    Text(m.selected!.level,
                        style:
                            TextStyle(fontSize: 15, color: Colors.grey[600])),
                    const SizedBox(height: 12),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      _stars(m.averageStar, 28),
                      const SizedBox(width: 8),
                      Text(
                          '${m.averageStar.toStringAsFixed(1)} (${m.ratingCount}人)',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ]),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              _buildMyRating(m, isDark),
              const SizedBox(height: 20),
              if (m.ratings.isNotEmpty) ...[
                Text('${m.ratingCount}人评价',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87)),
                const SizedBox(height: 8),
                ...m.ratings.map((r) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isDark ? Colors.grey[800] : Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                CircleAvatar(
                                    radius: 14,
                                    backgroundColor: const Color(0xFF6366F1),
                                    child: Text(
                                        r.userName.isNotEmpty
                                            ? r.userName[0]
                                            : '?',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12))),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(r.userName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14))),
                                _stars(r.star.toDouble(), 14),
                              ]),
                              if (r.comment.isNotEmpty)
                                Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(r.comment,
                                        style: TextStyle(
                                            color: isDark
                                                ? Colors.grey[300]
                                                : Colors.grey[700],
                                            fontSize: 14))),
                            ]),
                      ),
                    )),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildMyRating(MajorProvider m, bool isDark) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isLoggedIn)
      return const Card(
          child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text('请先登录后评价'))));
    return Card(
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('我的评价',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87)),
              const Spacer(),
              if (!_editing)
                TextButton(
                    onPressed: () => setState(() {
                          _editing = true;
                          if (m.myRating != null) {
                            _star = m.myRating!.star;
                            _commentCtrl.text = m.myRating!.comment;
                          }
                        }),
                    child: Text(m.myRating == null ? '打分' : '修改')),
            ]),
            if (!_editing && m.myRating != null) ...[
              _stars(m.myRating!.star.toDouble(), 28),
              if (m.myRating!.comment.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(m.myRating!.comment,
                        style: TextStyle(
                            color:
                                isDark ? Colors.grey[300] : Colors.grey[700]))),
            ] else if (!_editing) ...[
              const Text('点击打分按钮进行评价', style: TextStyle(color: Colors.grey)),
            ] else ...[
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
                                  : Colors.grey[400])))),
              const SizedBox(height: 8),
              TextField(
                  controller: _commentCtrl,
                  maxLength: 500,
                  decoration: const InputDecoration(
                      hintText: '说说感受...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12)),
                  maxLines: 3),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: () => setState(() => _editing = false),
                    child: const Text('取消')),
                ElevatedButton(
                    onPressed: _star == 0
                        ? null
                        : () async {
                            await m.rate(
                                widget.majorId, _star, _commentCtrl.text);
                            if (mounted) setState(() => _editing = false);
                          },
                    child: Text(m.myRating == null ? '提交' : '更新')),
              ]),
            ],
          ])),
    );
  }

  Widget _stars(double avg, double size) => Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
          5,
          (i) => Icon(i < avg.round() ? Icons.star : Icons.star_border,
              size: size,
              color: i < avg.round() ? Colors.amber : Colors.grey[400])));
}
