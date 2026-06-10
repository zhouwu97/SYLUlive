import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io' show File;

import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'post_detail_screen.dart';

class MarketExposureScreen extends StatelessWidget {
  const MarketExposureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('曝光台'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground(themeProvider, isDark)),
          Consumer<PostProvider>(
            builder: (context, postProvider, child) {
              final exposurePosts = postProvider
                  .postsFor(2)
                  .where((post) => post.postType == 'exposure')
                  .toList();

              if (postProvider.isLoadingFor(2) && exposurePosts.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }

              if (exposurePosts.isEmpty) {
                return Center(
                  child: GlassContainer(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    borderRadius: 20,
                    blur: 12,
                    opacity: 0.18,
                    backgroundColor: isDark
                        ? const Color(0x99171B24)
                        : const Color(0xCCFFFFFF),
                    borderColor: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.72),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 44,
                          color: isDark ? Colors.white38 : Colors.grey[500],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '暂无曝光内容',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '有新的举报内容时会出现在这里',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white38 : Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return RefreshIndicator(
                onRefresh: () => postProvider.refresh(boardId: 2, sort: 'time'),
                child: ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: exposurePosts.length,
                  itemBuilder: (context, index) {
                    final post = exposurePosts[index];
                    return PostCard(
                      post: post,
                      showWarning: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PostDetailScreen(
                            postId: post.id,
                            isMarket: true,
                            initialPost: post,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.isBackgroundVisible && themeProvider.getBackgroundImageFor(context) != null) {
      final bgPath = themeProvider.getBackgroundImageFor(context)!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset(
                  'assets/images/$bgPath',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                )
              : bgPath.startsWith('/')
                  ? Image.file(
                      File(bgPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    )
                  : Image.network(
                      bgPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.25),
          ),
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
}
