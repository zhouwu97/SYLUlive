import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/reply.dart';
import '../providers/auth_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/cached_avatar.dart';
import '../config/api_constants.dart';
import 'post_detail_screen.dart';

class UserRepliesScreen extends StatefulWidget {
  const UserRepliesScreen({super.key});

  @override
  State<UserRepliesScreen> createState() => _UserRepliesScreenState();
}

class _UserRepliesScreenState extends State<UserRepliesScreen> {
  List<Reply> _replies = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadReplies();
  }

  Future<void> _loadReplies() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final auth = context.read<AuthProvider>();
      final response = await auth.dio.get('/user/replies/received');
      if (response.statusCode == 200) {
        final list = (response.data as List).map((e) => Reply.fromJson(e)).toList();
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        setState(() {
          _replies = list;
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = '获取失败: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '暂无网络或后端接口未部署\n详细信息: $e';
        _isLoading = false;
      });
    }
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('收到的回复'),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildErrorView(isDark)
              : _replies.isEmpty
                  ? _buildEmptyView(isDark)
                  : RefreshIndicator(
                      onRefresh: _loadReplies,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics()),
                        padding: const EdgeInsets.all(16),
                        itemCount: _replies.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final reply = _replies[index];
                          return _buildReplyCard(reply, isDark);
                        },
                      ),
                    ),
    );
  }

  Widget _buildReplyCard(Reply reply, bool isDark) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PostDetailScreen(
              postId: reply.postId,
              targetReplyId: reply.id,
            ),
          ),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: GlassContainer(
        padding: const EdgeInsets.all(12),
        borderRadius: 12,
        blur: 8,
        opacity: isDark ? 0.15 : 0.3,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CachedAvatar(
              radius: 20,
              imageUrl: reply.author?.avatar.isNotEmpty == true
                  ? ApiConstants.fullUrl(reply.author!.avatar)
                  : null,
              fallbackText: reply.author?.nickname,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        reply.author?.nickname ?? '匿名用户',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      Text(
                        _formatTime(reply.createdAt),
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white30 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '回复了您的帖子',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    reply.content,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white70 : Colors.black87,
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined,
              size: 64, color: isDark ? Colors.white30 : Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无收到的回复',
              style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 64, color: isDark ? Colors.white30 : Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadReplies,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
