import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'dart:io' show File;
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../config/api_constants.dart';
import '../models/post.dart';
import '../models/reply.dart';
import '../providers/post_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/post_image_cache.dart';
import '../widgets/glass_container.dart';
import '../widgets/report_sheet.dart';
import 'create_post_screen.dart';
import 'image_viewer_screen.dart';

class PostDetailScreen extends StatefulWidget {
  final int postId;
  final bool isMarket;
  final Post? initialPost;

  const PostDetailScreen(
      {super.key,
      required this.postId,
      this.isMarket = false,
      this.initialPost});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  late Dio _dio;
  Post? _post;
  List<Reply> _replies = [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _liked = false;
  int _likeCount = 0;
  final _replyController = TextEditingController();
  final _replyFocus = FocusNode();
  bool _isReplyComposerOpen = false;
  int _marketImageIndex = 0;

  @override
  void initState() {
    super.initState();
    _dio = context.read<AuthProvider>().dio;
    if (widget.initialPost != null) {
      _post = widget.initialPost;
      _isLoading = false;
    }
    _loadPost();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  Future<void> _loadPost() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final response = await _dio.get('/posts/${widget.postId}');
      final repliesResponse = await _dio.get('/posts/${widget.postId}/replies');
      final fetchedPost = Post.fromJson(response.data);
      final fallbackPost = widget.initialPost;
      final mergedPost = fallbackPost != null &&
              fallbackPost.images.length > fetchedPost.images.length
          ? Post(
              id: fetchedPost.id,
              title: fetchedPost.title,
              content: fetchedPost.content,
              boardId: fetchedPost.boardId,
              authorId: fetchedPost.authorId,
              postType: fetchedPost.postType,
              price: fetchedPost.price,
              contact: fetchedPost.contact,
              status: fetchedPost.status,
              images: fallbackPost.images,
              author: fetchedPost.author,
              createdAt: fetchedPost.createdAt,
            )
          : fetchedPost;
      setState(() {
        _post = mergedPost;
        _replies = (repliesResponse.data as List)
            .map((e) => Reply.fromJson(e))
            .toList();
        _isLoading = false;
      });
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '加载帖子失败');
      setState(() {
        _isLoading = false;
        _errorMessage = msg;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  Future<void> _toggleLike() async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    setState(() {
      _liked = !_liked;
      _likeCount += _liked ? 1 : -1;
    });
    try {
      await _dio.post('/posts/${widget.postId}/like');
    } catch (_) {
      setState(() {
        _liked = !_liked;
        _likeCount += _liked ? 1 : -1;
      });
    }
  }

  Future<void> _sendReply() async {
    final content = _replyController.text.trim();
    if (content.isEmpty) return;
    try {
      await _dio
          .post('/posts/${widget.postId}/replies', data: {'content': content});
      _replyController.clear();
      _replyFocus.unfocus();
      setState(() => _isReplyComposerOpen = false);
      _loadPost();
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '发送失败');
      if (mounted) {
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }

  Future<void> _deletePost() async {
    final post = _post;
    if (post == null) return;
    final postProvider = context.read<PostProvider>();

    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '删除帖子',
      message: '确定要删除这条帖子吗？删除后普通用户不可见，此操作不可撤销。',
    );
    if (!confirmed) return;

    final result = await postProvider.deletePostDetailed(post.id);
    if (!mounted) return;
    if (result.success) {
      AppFeedback.showSnackBar(context, '帖子已删除');
      Navigator.pop(context, true);
    } else {
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '删除帖子失败',
        isError: true,
      );
    }
  }

  Future<void> _editPost() async {
    final post = _post;
    if (post == null) return;
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: post.boardId,
          defaultPostType: post.postType,
          editingPost: post,
        ),
      ),
    );
    if (updated == true && mounted) {
      await _loadPost();
    }
  }

  Future<void> _resolveMarketPost() async {
    final post = _post;
    if (post == null) return;
    final actionLabel = _marketCompleteLabel(post.postType);
    final postProvider = context.read<PostProvider>();
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: actionLabel,
      message: '确认后会直接删除这条帖子，避免继续占用集市列表。此操作不可撤销。',
    );
    if (!confirmed) return;
    final result = await postProvider.deletePostDetailed(post.id);
    if (!mounted) return;
    if (result.success) {
      AppFeedback.showSnackBar(context, '$actionLabel，帖子已移除');
      Navigator.pop(context, true);
    } else {
      AppFeedback.showSnackBar(
        context,
        result.errorMessage ?? '$actionLabel失败',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final currentUser = context.watch<AuthProvider>().user;
    final canDelete = _post != null &&
        currentUser != null &&
        (currentUser.id == _post!.authorId || currentUser.isAdmin);
    final canEditMarket = widget.isMarket && _isCurrentUserPostOwner();

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF131720) : Colors.white,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        actions: [
          if (canEditMarket)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑帖子',
              onPressed: _editPost,
            ),
          if (canDelete)
            IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red[300]),
              tooltip: '删除帖子',
              onPressed: _deletePost,
            ),
          IconButton(
            icon: Icon(Icons.report_outlined, color: Colors.red[300]),
            tooltip: '举报',
            onPressed: () => showReportSheet(context,
                targetId: widget.postId, targetType: 'post'),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 内容
          SafeArea(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? _buildErrorView(isDark)
                    : _post == null
                        ? _buildEmptyView(isDark)
                        : widget.isMarket
                            ? _buildMarketDetail(isDark)
                            : _buildWaterDetail(isDark),
          ),
        ],
      ),
    );
  }

  // ---- 错误 / 空 ----

  Widget _buildErrorView(bool isDark) {
    return Center(
        child: Padding(
      padding: const EdgeInsets.all(40),
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF171B24) : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off,
              size: 48, color: isDark ? Colors.white30 : Colors.grey[400]),
          const SizedBox(height: 14),
          Text(_errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 15)),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _loadPost,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ),
    ));
  }

  Widget _buildEmptyView(bool isDark) {
    return Center(
        child: Text('帖子不存在',
            style: TextStyle(
                color: isDark ? Colors.white54 : Colors.grey[500],
                fontSize: 15)));
  }

  // ---- 集市布局 ----

  Widget _buildMarketDetail(bool isDark) {
    final p = _post!;
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildAuthorCard(p, isDark),
            const SizedBox(height: 16),
            if (p.images.isNotEmpty) ...[
              _buildHeroImage(p, isDark),
              const SizedBox(height: 16),
            ],
            if (p.title.isNotEmpty || p.content.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p.title.isNotEmpty) ...[
                      Text(p.title,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87)),
                      const SizedBox(height: 10),
                    ],
                    if (p.price > 0) ...[
                      Text(
                          '¥ ${p.price.toStringAsFixed(p.price.truncateToDouble() == p.price ? 0 : 2)}',
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFFFF6B6B))),
                      const SizedBox(height: 12),
                    ],
                    Text(p.content,
                        style: TextStyle(
                            fontSize: 15,
                            height: 1.7,
                            color: isDark ? Colors.white70 : Colors.black87)),
                    if (p.contact.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: p.contact));
                          AppFeedback.showSnackBar(context, '联系方式已复制到剪贴板');
                        },
                        child: _buildContactChip(p.contact, isDark),
                      ),
                    ],
                  ],
                ),
              ),
            if (_isCurrentUserPostOwner()) ...[
              const SizedBox(height: 18),
              _buildOwnerMarketActions(isDark),
            ],
            const SizedBox(height: 28),
            _buildActionBar(isDark),
            const SizedBox(height: 24),
            _buildCommentsHeader(isDark),
            const SizedBox(height: 10),
            _buildCompactReplies(isDark),
          ]),
        ),
      ),
      _buildReplyBar(isDark),
    ]);
  }

  // ---- 水帖布局 ----

  Widget _buildWaterDetail(bool isDark) {
    final p = _post!;
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildAuthorCard(p, isDark),
            const SizedBox(height: 18),
            if (p.title.isNotEmpty || p.content.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p.title.isNotEmpty) ...[
                      Text(p.title,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87)),
                      const SizedBox(height: 12),
                    ],
                    Text(p.content,
                        style: TextStyle(
                            fontSize: 16,
                            height: 1.75,
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.80)
                                : Colors.black87)),
                  ],
                ),
              ),
            if (p.images.isNotEmpty) ...[
              const SizedBox(height: 18),
              _buildImageGrid(p, isDark),
            ],
            const SizedBox(height: 28),
            _buildActionBar(isDark),
            const SizedBox(height: 24),
            _buildCommentsHeader(isDark),
            const SizedBox(height: 10),
            _buildFullReplies(isDark),
          ]),
        ),
      ),
      _buildReplyBar(isDark),
    ]);
  }

  // ---- 作者卡片 ----

  Widget _buildAuthorCard(Post p, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0x99171B24) : const Color(0x0A000000),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: isDark ? Colors.white12 : Colors.grey[200],
          backgroundImage: p.author?.avatar.isNotEmpty == true
              ? NetworkImage(ApiConstants.fullUrl(p.author!.avatar))
              : null,
          child: p.author?.avatar.isEmpty != false
              ? Text(
                  p.author?.nickname.isNotEmpty == true
                      ? p.author!.nickname[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: isDark ? Colors.white70 : Colors.grey[700]))
              : null,
        ),
        const SizedBox(width: 14),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.author?.nickname ?? '匿名',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: isDark ? Colors.white : Colors.black87)),
            const SizedBox(height: 4),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: _creditColor(p.author?.creditScore ?? 100)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('诚信 ${p.author?.creditScore ?? 100}%',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _creditColor(p.author?.creditScore ?? 100))),
              ),
            ]),
          ]),
        ),
        Text(_formatTime(p.createdAt),
            style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white30 : Colors.grey[400])),
      ]),
    );
  }

  // ---- 图片 ----

  Widget _buildHeroImage(Post p, bool isDark) {
    final urls = _resolvedImageUrls(p);
    if (urls.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            height: 340,
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
            child: PageView.builder(
              itemCount: urls.length,
              onPageChanged: (index) =>
                  setState(() => _marketImageIndex = index),
              itemBuilder: (_, index) => GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ImageViewerScreen(
                      imageUrls: urls,
                      initialIndex: index,
                    ),
                  ),
                ),
                child: CachedNetworkImage(
                  cacheManager: PostImageCache.manager,
                  imageUrl: urls[index],
                  width: double.infinity,
                  fit: BoxFit.contain,
                  placeholder: (_, __) => Container(
                    height: 340,
                    color: isDark ? Colors.white10 : Colors.grey[200],
                  ),
                  errorWidget: (_, __, ___) => Container(
                    height: 340,
                    color: isDark ? Colors.white10 : Colors.grey[200],
                    child: const Icon(
                      Icons.broken_image,
                      size: 40,
                      color: Colors.grey,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (urls.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              urls.length,
              (index) => AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: _marketImageIndex == index ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _marketImageIndex == index
                      ? Theme.of(context).primaryColor
                      : Colors.white.withValues(alpha: isDark ? 0.35 : 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildImageGrid(Post p, bool isDark) {
    final images = _resolvedImageUrls(p);
    if (images.isEmpty) return const SizedBox.shrink();
    if (images.length == 1) return _buildHeroImage(p, isDark);
    final crossCount = images.length == 2 ? 2 : 3;
    final displayImages = images.length > 4 ? images.sublist(0, 4) : images;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossCount,
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
            childAspectRatio: 1),
        itemCount: displayImages.length,
        itemBuilder: (context, index) => GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                      imageUrls: images, initialIndex: index))),
          child: Stack(fit: StackFit.expand, children: [
            CachedNetworkImage(
                cacheManager: PostImageCache.manager,
                imageUrl: displayImages[index],
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey[300]),
                errorWidget: (_, __, ___) => Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.broken_image))),
            if (index == 3 && images.length > 4)
              Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: Text('+${images.length - 3}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold))),
          ]),
        ),
      ),
    );
  }

  // ---- 操作栏 ----

  Widget _buildActionBar(bool isDark) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
      _buildActionButton(
        icon: _liked ? Icons.favorite : Icons.favorite_border,
        color: _liked
            ? const Color(0xFFFF6B6B)
            : (isDark ? Colors.white38 : Colors.grey.shade500),
        label: '$_likeCount',
        onTap: _toggleLike,
      ),
      _buildActionButton(
        icon: Icons.chat_bubble_outline,
        color: isDark ? Colors.white38 : Colors.grey.shade500,
        label: '${_replies.length}',
        onTap: _openReplyComposer,
      ),
      IconButton(
        icon: Icon(Icons.report_outlined,
            color: isDark ? Colors.white30 : Colors.grey[400], size: 20),
        onPressed: () => showReportSheet(context,
            targetId: widget.postId, targetType: 'post'),
        tooltip: '举报',
      ),
    ]);
  }

  Widget _buildOwnerMarketActions(bool isDark) {
    final post = _post!;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _editPost,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('编辑内容'),
            style: OutlinedButton.styleFrom(
              foregroundColor: isDark ? Colors.white : Colors.black87,
              side: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.black.withValues(alpha: 0.08),
              ),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: _resolveMarketPost,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: Text(_marketCompleteLabel(post.postType)),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(
      {required IconData icon,
      required Color color,
      required String label,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  // ---- 联系方式 ----

  Widget _buildContactChip(String contact, bool isDark) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      borderRadius: 14,
      blur: 10,
      opacity: 0.16,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.contact_phone_outlined,
            size: 16, color: isDark ? Colors.white54 : Colors.grey[600]),
        const SizedBox(width: 8),
        Text(contact,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.grey[700])),
      ]),
    );
  }

  // ---- 评论区 ----

  Widget _buildCommentsHeader(bool isDark) {
    return Row(children: [
      Icon(Icons.forum_outlined,
          size: 18, color: isDark ? Colors.white30 : Colors.grey[500]),
      const SizedBox(width: 8),
      Text('全部评论 ${_replies.length}',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white38 : Colors.grey[500])),
    ]);
  }

  Widget _buildCompactReplies(bool isDark) {
    if (_replies.isEmpty) return _buildNoComments(isDark);
    return Column(
      children:
          _replies.take(4).map((r) => _buildReplyBubble(r, isDark)).toList(),
    );
  }

  Widget _buildFullReplies(bool isDark) {
    if (_replies.isEmpty) return _buildNoComments(isDark);
    return Column(
      children: _replies.map((r) => _buildReplyBubble(r, isDark)).toList(),
    );
  }

  Widget _buildNoComments(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
          child: Column(children: [
        Icon(Icons.chat_bubble_outline,
            size: 32, color: isDark ? Colors.white30 : Colors.grey.shade300),
        const SizedBox(height: 8),
        Text('还没有评论',
            style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white30 : Colors.grey[400])),
      ])),
    );
  }

  Widget _buildReplyBubble(Reply r, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: isDark ? Colors.white12 : Colors.grey[200],
          backgroundImage: r.author?.avatar.isNotEmpty == true
              ? NetworkImage(ApiConstants.fullUrl(r.author!.avatar))
              : null,
          child: r.author?.avatar.isEmpty != false
              ? Text(
                  r.author?.nickname.isNotEmpty == true
                      ? r.author!.nickname[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white60 : Colors.grey[600]))
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GlassContainer(
            padding: const EdgeInsets.all(12),
            borderRadius: 14,
            blur: 10,
            opacity: 0.16,
            backgroundColor:
                isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(r.author?.nickname ?? '匿名',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.80)
                            : Colors.black87)),
                const Spacer(),
                GestureDetector(
                  onTap: () => showReportSheet(context,
                      targetId: r.id, targetType: 'reply'),
                  child: Icon(Icons.report_outlined,
                      size: 14,
                      color: isDark ? Colors.white24 : Colors.grey[400]),
                ),
                const SizedBox(width: 8),
                Text(_formatTime(r.createdAt),
                    style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white30 : Colors.grey[400])),
              ]),
              const SizedBox(height: 6),
              Text(r.content,
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: isDark ? Colors.white60 : Colors.grey[700])),
            ]),
          ),
        ),
      ]),
    );
  }

  // ---- 回复输入 ----

  Widget _buildReplyBar(bool isDark) {
    if (!_isReplyComposerOpen) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1E1E32).withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, -3))
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(children: [
            GestureDetector(
              onTap: () {
                _replyFocus.unfocus();
                setState(() => _isReplyComposerOpen = false);
              },
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white10
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: isDark ? Colors.white54 : Colors.grey[700],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _replyController,
                focusNode: _replyFocus,
                decoration: InputDecoration(
                  hintText: '写下你的想法...',
                  hintStyle: TextStyle(
                      color: isDark ? Colors.white30 : Colors.grey[400],
                      fontSize: 14),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white : Colors.black87),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _sendReply,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF667EEA), Color(0xFF764BA2)]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.send_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ---- 工具 ----

  Color _creditColor(int score) {
    if (score >= 90) return const Color(0xFF4CAF50);
    if (score >= 70) return const Color(0xFFFF9800);
    return const Color(0xFFF44336);
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }

  String _marketCompleteLabel(String postType) {
    switch (postType) {
      case 'sell':
        return '已售出';
      case 'buy':
        return '已买到';
      case 'proxy':
        return '已完成';
      case 'lost':
      case 'found':
        return '已解决';
      default:
        return '已处理';
    }
  }

  bool _isCurrentUserPostOwner() {
    final post = _post;
    final currentUser = context.read<AuthProvider>().user;
    return widget.isMarket &&
        post != null &&
        currentUser != null &&
        currentUser.id == post.authorId;
  }

  List<String> _resolvedImageUrls(Post post) {
    return post.images
        .map((image) => ApiConstants.fullUrl(image.url))
        .where((url) => url.trim().isNotEmpty)
        .toList();
  }

  void _openReplyComposer() {
    setState(() => _isReplyComposerOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _replyFocus.requestFocus();
      }
    });
  }
}
