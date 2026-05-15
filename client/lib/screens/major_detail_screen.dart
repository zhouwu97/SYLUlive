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
  const MajorDetailScreen({super.key, required this.majorId, required this.majorName});
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
  void dispose() { _commentCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF131720) : Colors.white,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text(widget.majorName),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: Stack(
          children: [
            Positioned.fill(child: _buildBackground(themeProvider, isDark)),
            Consumer<MajorProvider>(
              builder: (_, m, __) {
                if (m.isLoading) return const Center(child: CircularProgressIndicator());
                if (m.selected == null) return const Center(child: Text('加载失败'));
                return SafeArea(
                  child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                  children: [
                    Card(
                      color: isDark ? Colors.grey[850] : Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(children: [
                          CircleAvatar(radius: 36, backgroundColor: const Color(0xFF6366F1), child: Text(m.selected!.name[0], style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold))),
                          const SizedBox(height: 12),
                          Text(m.selected!.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          Text(m.selected!.level, style: TextStyle(fontSize: 15, color: Colors.grey[600])),
                          const SizedBox(height: 12),
                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            _stars(m.averageStar, 28), const SizedBox(width: 8),
                            Text('${m.averageStar.toStringAsFixed(1)} (${m.ratingCount}人)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          ]),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildMyRating(m, isDark),
                    const SizedBox(height: 20),
                    if (m.ratings.isNotEmpty) ...[
                      Text('${m.ratingCount}人评价', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
                      const SizedBox(height: 8),
                      ...m.ratings.map((r) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        color: isDark ? Colors.grey[800] : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              CircleAvatar(radius: 14, backgroundColor: const Color(0xFF6366F1), child: Text(r.userName.isNotEmpty ? r.userName[0] : '?', style: const TextStyle(color: Colors.white, fontSize: 12))),
                              const SizedBox(width: 8),
                              Expanded(child: Text(r.userName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
                              _stars(r.star.toDouble(), 14),
                            ]),
                            if (r.comment.isNotEmpty)
                              Padding(padding: const EdgeInsets.only(top: 6), child: Text(r.comment, style: TextStyle(color: isDark ? Colors.grey[300] : Colors.grey[700], fontSize: 14))),
                          ]),
                        ),
                      )),
                    ],
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
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath', fit: BoxFit.cover, errorBuilder: (_, __, ___) => _defaultBg(isDark))
            : bgPath.startsWith('/')
                ? Image.file(File(bgPath), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _defaultBg(isDark))
                : Image.network(bgPath, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _defaultBg(isDark)),
        Container(color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.25)),
      ]);
    }
    return _defaultBg(isDark);
  }

  Widget _defaultBg(bool isDark) => Stack(fit: StackFit.expand, children: [
    Image.asset('assets/images/morenbeijing.jpeg', fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB))),
    Container(color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.22)),
  ]);

  Widget _buildMyRating(MajorProvider m, bool isDark) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isLoggedIn) return const Card(child: Padding(padding: EdgeInsets.all(16), child: Center(child: Text('请先登录后评价'))));
    return Card(color: isDark ? Colors.grey[850] : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('我的评价', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87)),
          const Spacer(),
          if (!_editing) TextButton(onPressed: () => setState(() {
            _editing = true;
            if (m.myRating != null) { _star = m.myRating!.star; _commentCtrl.text = m.myRating!.comment; }
          }), child: Text(m.myRating == null ? '打分' : '修改')),
        ]),
        if (!_editing && m.myRating != null) ...[
          _stars(m.myRating!.star.toDouble(), 28),
          if (m.myRating!.comment.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(m.myRating!.comment, style: TextStyle(color: isDark ? Colors.grey[300] : Colors.grey[700]))),
        ] else if (!_editing) ...[
          const Text('点击打分按钮进行评价', style: TextStyle(color: Colors.grey)),
        ] else ...[
          Row(children: List.generate(5, (i) => GestureDetector(onTap: () => setState(() => _star = i + 1), child: Icon(i < _star ? Icons.star : Icons.star_border, size: 36, color: i < _star ? Colors.amber : Colors.grey[400])))),
          const SizedBox(height: 8),
          TextField(controller: _commentCtrl, maxLength: 500, decoration: const InputDecoration(hintText: '说说感受...', border: OutlineInputBorder(), contentPadding: EdgeInsets.all(12)), maxLines: 3),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => setState(() => _editing = false), child: const Text('取消')),
            ElevatedButton(onPressed: _star == 0 ? null : () async {
              await m.rate(widget.majorId, _star, _commentCtrl.text);
              if (mounted) setState(() => _editing = false);
            }, child: Text(m.myRating == null ? '提交' : '更新')),
          ]),
        ],
      ])),
    );
  }

  Widget _stars(double avg, double size) => Row(mainAxisSize: MainAxisSize.min, children: List.generate(5, (i) => Icon(i < avg.round() ? Icons.star : Icons.star_border, size: size, color: i < avg.round() ? Colors.amber : Colors.grey[400])));
}
