import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post.dart';
import '../models/reply.dart';
import '../models/user.dart';
import 'image_viewer_screen.dart';

class PostDetailScreen extends StatefulWidget {
  final int postId;

  const PostDetailScreen({super.key, required this.postId});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final Dio _dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  Post? _post;
  List<Reply> _replies = [];
  bool _isLoading = true;
  final _replyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPost();
  }

  Future<void> _loadPost() async {
    try {
      final response = await _dio.get('/posts/${widget.postId}');
      final repliesResponse = await _dio.get('/posts/${widget.postId}/replies');

      setState(() {
        _post = Post.fromJson(response.data);
        _replies = (repliesResponse.data as List)
            .map((e) => Reply.fromJson(e))
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('加载帖子失败: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _sendReply() async {
    if (_replyController.text.isEmpty) return;

    try {
      await _dio.post('/posts/${widget.postId}/replies', data: {
        'content': _replyController.text,
      });
      _replyController.clear();
      _loadPost();
    } catch (e) {
      debugPrint('发送回复失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_post?.title ?? '帖子详情'),
        actions: [
          if (_post != null)
            IconButton(
              icon: const Icon(Icons.message),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('私信功能暂时关闭')),
                );
              },
              tooltip: '联系TA',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _post == null
              ? const Center(child: Text('帖子不存在'))
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        children: [
                          _buildPostContent(),
                          const Divider(),
                          _buildReplies(),
                        ],
                      ),
                    ),
                    _buildReplyInput(),
                  ],
                ),
    );
  }

  Widget _buildPostContent() {
    if (_post == null) return const SizedBox();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 作者信息
          Row(
            children: [
              CircleAvatar(
                backgroundImage: _post!.author?.avatar.isNotEmpty == true
                    ? NetworkImage(_post!.author!.avatar)
                    : null,
                child: _post!.author?.avatar.isEmpty == true
                    ? Text(_post!.author?.nickname.substring(0, 1) ?? '?')
                    : null,
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _post!.author?.nickname ?? '匿名',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '诚信度: ${_post!.author?.creditScore ?? 100}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 标题
          if (_post!.title.isNotEmpty) ...[
            Text(
              _post!.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
          ],

          // 内容
          Text(_post!.content),

          // 价格信息
          if (_post!.price > 0) ...[
            const SizedBox(height: 8),
            Text(
              '价格: ¥${_post!.price.toStringAsFixed(2)}',
              style: TextStyle(
                color: Theme.of(context).primaryColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],

          // 图片
          if (_post!.images.isNotEmpty) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _post!.images.length,
                itemBuilder: (context, index) {
                  final image = _post!.images[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ImageViewerScreen(
                            imageUrls: _post!.images.map((e) => e.url).toList(),
                            initialIndex: index,
                          ),
                        ),
                      );
                    },
                    onLongPress: () {
                      // 保存图片功能预留
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CachedNetworkImage(
                        imageUrl: image.url,
                        width: 200,
                        fit: BoxFit.cover,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReplies() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '回复 (${_replies.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_replies.isEmpty)
            const Text('暂无回复')
          else
            ..._replies.map((reply) => _buildReplyItem(reply)),
        ],
      ),
    );
  }

  Widget _buildReplyItem(Reply reply) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundImage: reply.author?.avatar.isNotEmpty == true
                      ? NetworkImage(reply.author!.avatar)
                      : null,
                  child: reply.author?.avatar.isEmpty == true
                      ? Text(reply.author?.nickname.substring(0, 1) ?? '?')
                      : null,
                ),
                const SizedBox(width: 8),
                Text(
                  reply.author?.nickname ?? '匿名',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  _formatTime(reply.createdAt),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(reply.content),
          ],
        ),
      ),
    );
  }

  Widget _buildReplyInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _replyController,
                decoration: const InputDecoration(
                  hintText: '写下你的回复...',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _sendReply,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dateTime.month}/${dateTime.day}';
  }
}

class MessageScreen {}