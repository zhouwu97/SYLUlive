import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/major_provider.dart';

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
  final _commentCtrl = TextEditingController();
  int _star = 0;
  bool _editing = false;
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
    _commentCtrl.dispose();
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
      if (ok) {
        _editing = false;
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
        title: Text(widget.majorName),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (context.watch<AuthProvider>().user?.isAdmin == true)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: _deleteMajor,
            ),
        ],
      ),
      body: Consumer<MajorProvider>(
        builder: (_, m, __) {
          if (m.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (m.selected == null) return const Center(child: Text('加载失败'));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
            children: [
              _buildHeader(m, isDark),
              const SizedBox(height: 12),
              _buildMyRating(m, isDark),
              const SizedBox(height: 18),
              _buildRatingSection(m, isDark),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
    );
  }

  Color _surfaceColor(bool isDark) =>
      isDark ? const Color(0xFF1C2230) : Colors.white;

  Color _mutedTextColor(bool isDark) =>
      isDark ? Colors.grey.shade300 : Colors.grey.shade600;

  String _initial(String text) {
    final value = text.trim();
    return value.isEmpty ? '?' : value[0];
  }

  Widget _buildHeader(MajorProvider m, bool isDark) {
    final major = m.selected!;

    return Card(
      elevation: 0,
      color: _surfaceColor(isDark),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: const Color(0xFF6366F1),
              child: Text(
                _initial(major.name),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 27,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              major.name,
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
              major.level,
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
                  _stars(m.averageStar, 28),
                  const SizedBox(width: 8),
                  Text(
                    '${m.averageStar.toStringAsFixed(1)} (${m.ratingCount}人)',
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
      ),
    );
  }

  Widget _buildMyRating(MajorProvider m, bool isDark) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isLoggedIn) {
      return Card(
        elevation: 0,
        color: _surfaceColor(isDark),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              '请先登录后评价',
              style: TextStyle(color: isDark ? Colors.white : Colors.black87),
            ),
          ),
        ),
      );
    }
    return Card(
      elevation: 0,
      color: _surfaceColor(isDark),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onLongPress: m.myRating != null && !_editing
            ? () => _confirmDeleteRating(m.myRating!)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                  if (!_editing)
                    TextButton(
                      onPressed: () => setState(() {
                        _editing = true;
                        _star = m.myRating?.star ?? 0;
                        _commentCtrl.text = m.myRating?.comment ?? '';
                      }),
                      child: Text(m.myRating == null ? '打分' : '修改'),
                    ),
                ],
              ),
              if (!_editing && m.myRating != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    _stars(m.myRating!.star.toDouble(), 28),
                    const SizedBox(width: 10),
                    Text(
                      '${m.myRating!.star}.0分',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (m.myRating!.comment.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      m.myRating!.comment.trim(),
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: _mutedTextColor(isDark),
                      ),
                    ),
                  ),
              ] else if (!_editing) ...[
                const SizedBox(height: 6),
                Text(
                  '点击右侧按钮进行评价',
                  style:
                      TextStyle(fontSize: 13, color: _mutedTextColor(isDark)),
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
                  maxLength: 500,
                  decoration: InputDecoration(
                    hintText: '说说感受...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? const Color(0x33FFFFFF)
                        : const Color(0x0A000000),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _editing = false;
                        _star = m.myRating?.star ?? 0;
                        _commentCtrl.text = m.myRating?.comment ?? '';
                      }),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _star == 0
                          ? null
                          : () async {
                              await m.rate(
                                widget.majorId,
                                _star,
                                _commentCtrl.text.trim(),
                              );
                              if (mounted) setState(() => _editing = false);
                            },
                      child: Text(m.myRating == null ? '提交' : '更新'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRatingSection(MajorProvider m, bool isDark) {
    if (m.ratings.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${m.ratingCount}人评价',
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
        const SizedBox(height: 10),
        ...m.ratings.map((r) => _buildRatingCard(r, isDark)),
      ],
    );
  }

  Widget _buildRatingCard(MajorRating r, bool isDark) {
    final isOwn = _isOwnRating(r);
    final comment = r.comment.trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: _surfaceColor(isDark),
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
              _stars(r.star.toDouble(), 14),
            ],
          ),
        ),
      ),
    );
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
}
