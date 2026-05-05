import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/post_provider.dart';
import '../widgets/post_card.dart';
import 'post_detail_screen.dart';

class MarketExposureScreen extends StatelessWidget {
  const MarketExposureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F131A) : const Color(0xFFF5F7FB),
      appBar: AppBar(
        title: const Text('曝光台'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Consumer<PostProvider>(
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
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF171B24) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : const Color(0xFFE8ECF4),
                  ),
                ),
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
                      builder: (_) =>
                          PostDetailScreen(postId: post.id, isMarket: true),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
