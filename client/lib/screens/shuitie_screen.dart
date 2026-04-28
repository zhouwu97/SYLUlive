import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/post_provider.dart';
import '../models/announcement.dart' as model;
import '../widgets/glass_container.dart';

class ShuitieScreen extends StatefulWidget {
  const ShuitieScreen({super.key});

  @override
  State<ShuitieScreen> createState() => _ShuitieScreenState();
}

class _ShuitieScreenState extends State<ShuitieScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  List<model.Announcement> _announcements = [];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PostProvider>().loadPosts(boardId: 1);
      _loadAnnouncements();
      _animationController.forward();
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    try {
      final response = await authProvider.dio.get('/announcements');
      if (response.statusCode == 200) {
        setState(() {
          _announcements = (response.data as List)
              .map((e) => model.Announcement.fromJson(e))
              .toList();
        });
      }
    } catch (e) {
      debugPrint('加载公告失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FadeTransition(
        opacity: CurvedAnimation(
          parent: _animationController,
          curve: Curves.easeOut,
        ),
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // 顶部应用栏
            SliverAppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              pinned: false,
              expandedHeight: 60,
              flexibleSpace: FlexibleSpaceBar(
                title: const Text(
                  '首页',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),

            // 公告轮播
            if (_announcements.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildAnnouncementBanner(isDark),
              ),

            // 发布按钮（已禁用）
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: GlassContainer(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  borderRadius: 25,
                  blur: themeProvider.liquidGlass ? 10 : 0,
                  opacity: themeProvider.liquidGlass ? 0.2 : 0,
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('论坛功能暂时关闭')),
                    );
                  },
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: Theme.of(context).primaryColor.withOpacity(0.2),
                        child: const Icon(Icons.edit, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '分享你的想法...',
                        style: TextStyle(
                          color: isDark ? Colors.white60 : Colors.grey[600],
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.add_circle,
                        color: Theme.of(context).primaryColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 帖子列表（暂时关闭）
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.forum_outlined,
                        size: 80,
                        color: isDark ? Colors.white24 : Colors.grey[300],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '由于不可抗力原因',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white70 : Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '论坛功能暂时关闭',
                        style: TextStyle(
                          fontSize: 18,
                          color: isDark ? Colors.white60 : Colors.grey[500],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '请别期待喵~',
                        style: TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: isDark ? Colors.white38 : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 底部留白
            const SliverToBoxAdapter(
              child: SizedBox(height: 100),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnnouncementBanner(bool isDark) {
    return SizedBox(
      height: 120,
      child: PageView.builder(
        itemCount: _announcements.length,
        controller: PageController(viewportFraction: 0.9),
        itemBuilder: (context, index) {
          final announcement = _announcements[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: GlassContainer(
              padding: const EdgeInsets.all(16),
              borderRadius: 16,
              blur: 10,
              opacity: 0.15,
              gradientColors: isDark
                  ? [Colors.blueGrey[800]!, Colors.blueGrey[900]!]
                  : [Colors.blue[50]!, Colors.blue[100]!],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.campaign,
                        color: Colors.blue[400],
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          announcement.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (announcement.isPinned)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '置顶',
                            style: TextStyle(color: Colors.red, fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Text(
                      announcement.content,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(24),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: isDark ? Colors.white60 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '暂无帖子',
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '发布第一条帖子吧！',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white.withValues(alpha: 0.4) : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }
}