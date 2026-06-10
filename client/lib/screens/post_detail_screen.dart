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
import '../models/user.dart';
import '../providers/post_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/post_image_cache.dart';
import '../widgets/glass_container.dart';
import '../widgets/report_sheet.dart';
import '../widgets/cached_avatar.dart';
import 'create_post_screen.dart';
import 'image_viewer_screen.dart';

class PostDetailScreen extends StatefulWidget {
  final int postId;
  final bool isMarket;
  final Post? initialPost;
  final int? targetReplyId;
  final bool isDesktopSplitMode;
  final bool hideBackButton;

  const PostDetailScreen(
      {super.key,
      required this.postId,
      this.isMarket = false,
      this.initialPost,
      this.targetReplyId,
      this.isDesktopSplitMode = false,
      this.hideBackButton = false});

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
  int? _parentReplyId;
  String? _replyToName;
  int? _replyToUserId;
  bool _isSending = false;
  final Set<int> _expandedThreads = {};

  final Map<int, GlobalKey> _replyKeys = {};
  bool _hasScrolledToTarget = false;

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
        _replies = (repliesResponse.data as List)
            .map((e) => Reply.fromJson(e))
            .toList();
        _post = mergedPost.copyWith(replyCount: _replies.length);
        _liked = mergedPost.isLiked;
        _likeCount = mergedPost.likeCount;
        _isLoading = false;
      });
      // 同步到外部列表以更新浏览量等数据
      if (mounted) {
        context.read<PostProvider>().updatePostInCache(_post!);
      }
      if (widget.targetReplyId != null && !_hasScrolledToTarget) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final key = _replyKeys[widget.targetReplyId];
          if (key != null && key.currentContext != null) {
            Scrollable.ensureVisible(
              key.currentContext!,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOut,
              alignment: 0.5,
            );
            _hasScrolledToTarget = true;
          }
        });
      }
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
      if (_post != null) {
        _post = _post!.copyWith(
          isLiked: _liked,
          likeCount: _likeCount,
        );
      }
    });
    if (_post != null) {
      context.read<PostProvider>().updatePostInCache(_post!);
    }

    try {
      if (_liked) {
        await _dio.post('/posts/${widget.postId}/like');
      } else {
        await _dio.delete('/posts/${widget.postId}/like');
      }
    } catch (_) {
      setState(() {
        _liked = !_liked;
        _likeCount += _liked ? 1 : -1;
        if (_post != null) {
          _post = _post!.copyWith(
            isLiked: _liked,
            likeCount: _likeCount,
          );
        }
      });
      if (_post != null) {
        context.read<PostProvider>().updatePostInCache(_post!);
      }
    }
  }

  Future<void> _sendReply() async {
    if (_isSending) return;
    final content = _replyController.text.trim();
    if (content.isEmpty) return;

    setState(() => _isSending = true);

    // 先保存 parentReplyId，后面 setState 会清空它
    final parentId = _parentReplyId;
    final replyTo = _replyToName;
    final replyToUserId = _replyToUserId;

    // 乐观更新：立即在本地插入评论
    final user = context.read<AuthProvider>().user;
    if (user != null && _post != null) {
      final tempId = -DateTime.now().millisecondsSinceEpoch;
      final tempReply = Reply(
        id: tempId,
        postId: widget.postId,
        authorId: user.id,
        content: content,
        createdAt: DateTime.now(),
        author: User(
          id: user.id,
          studentId: user.studentId,
          nickname: user.nickname,
          avatar: user.avatar,
          createdAt: DateTime.now(),
        ),
        parentReplyId: parentId,
      );
      _replies.insert(0, tempReply);
      _post = _post!.copyWith(replyCount: _post!.replyCount + 1);
      context.read<PostProvider>().updatePostInCache(_post!);
    }
    _replyController.clear();
    _replyFocus.unfocus();
    setState(() {
      _isReplyComposerOpen = false;
      _parentReplyId = null;
      _replyToName = null;
      _replyToUserId = null;
    });

    // 后台静默发送
    try {
      final formData = FormData.fromMap({
        'content': content,
        if (parentId != null) 'parent_reply_id': parentId.toString(),
        if (replyToUserId != null) 'reply_to_user_id': replyToUserId.toString(),
      });
      await _dio.post('/posts/${widget.postId}/replies', data: formData);
      // 静默刷新获取真实 ID
      final repliesResponse =
          await _dio.get('/posts/${widget.postId}/replies');
      if (mounted && repliesResponse.data is List) {
        setState(() {
          _replies = (repliesResponse.data as List)
              .map((r) => Reply.fromJson(r))
              .toList();
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _replies.removeWhere((r) => r.id < 0);
          if (_post != null) {
            _post = _post!.copyWith(replyCount: _post!.replyCount - 1);
          }
        });
        if (_post != null) {
          context.read<PostProvider>().updatePostInCache(_post!);
        }
        AppFeedback.showSnackBar(
            context, AppFeedback.dioErrorMessage(e, fallback: '发送失败'),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
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
        automaticallyImplyLeading: !widget.hideBackButton,
        leading: widget.hideBackButton ? null : const BackButton(),
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
          _isLoading
              ? const SafeArea(child: Center(child: CircularProgressIndicator()))
              : _errorMessage != null
                  ? SafeArea(child: _buildErrorView(isDark))
                  : _post == null
                      ? SafeArea(child: _buildEmptyView(isDark))
                      : widget.isMarket
                          ? _buildMarketDetail(isDark)
                          : SafeArea(child: _buildWaterDetail(isDark)),
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
    if (widget.isDesktopSplitMode) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧文本与评论区
          Expanded(
            flex: 5,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.title.isNotEmpty) ...[
                          Text(p.title,
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black87)),
                          const SizedBox(height: 12),
                        ],
                        if (p.price > 0) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('¥ ',
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFFF6B6B))),
                              Text(
                                p.price.toStringAsFixed(
                                    p.price.truncateToDouble() == p.price ? 0 : 2),
                                style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFFFF6B6B),
                                    height: 1.0),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(p.content,
                            style: TextStyle(
                                fontSize: 16,
                                height: 1.6,
                                color: isDark ? Colors.white70 : Colors.black87)),
                        const SizedBox(height: 24),
                        _buildAuthorCard(p, isDark),
                        if (p.contact.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: p.contact));
                              AppFeedback.showSnackBar(context, '联系方式已复制到剪贴板');
                            },
                            child: _buildContactChip(p.contact, isDark),
                          ),
                        ],
                        if (_isCurrentUserPostOwner()) ...[
                          const SizedBox(height: 24),
                          _buildOwnerMarketActions(isDark),
                        ],
                        const SizedBox(height: 32),
                        _buildActionBar(isDark),
                        const SizedBox(height: 24),
                        _buildCommentsHeader(isDark),
                        const SizedBox(height: 10),
                        _buildCompactReplies(isDark),
                      ],
                    ),
                  ),
                ),
                _buildReplyBar(isDark),
              ],
            ),
          ),
          // 右侧图片区域
          Container(
            width: 1,
            color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          ),
          Expanded(
            flex: 4,
            child: p.images.isNotEmpty
                ? _buildMarketHeroImage(p, isDark, forceFitHeight: true)
                : Container(
                    color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.image_not_supported_outlined, size: 64, color: isDark ? Colors.white24 : Colors.grey[300]),
                          const SizedBox(height: 16),
                          Text('没有图片展示', style: TextStyle(color: isDark ? Colors.white38 : Colors.grey[500], fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      );
    }

    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 80),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.images.isNotEmpty) 
                _buildMarketHeroImage(p, isDark)
              else
                SizedBox(height: MediaQuery.of(context).padding.top + kToolbarHeight),
              Transform.translate(
                offset: Offset(0, p.images.isNotEmpty ? -24 : 0),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF131720) : Colors.white,
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(p.images.isNotEmpty ? 24 : 0)),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (p.title.isNotEmpty) ...[
                        Text(p.title,
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87)),
                        const SizedBox(height: 12),
                      ],
                      if (p.price > 0) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text('¥ ',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFFF6B6B))),
                            Text(
                              p.price.toStringAsFixed(
                                  p.price.truncateToDouble() == p.price ? 0 : 2),
                              style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFFF6B6B),
                                  height: 1.0),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text(p.content,
                          style: TextStyle(
                              fontSize: 16,
                              height: 1.6,
                              color: isDark ? Colors.white70 : Colors.black87)),
                      const SizedBox(height: 24),
                      _buildAuthorCard(p, isDark),
                      if (p.contact.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: p.contact));
                            AppFeedback.showSnackBar(context, '联系方式已复制到剪贴板');
                          },
                          child: _buildContactChip(p.contact, isDark),
                        ),
                      ],
                      if (_isCurrentUserPostOwner()) ...[
                        const SizedBox(height: 24),
                        _buildOwnerMarketActions(isDark),
                      ],
                      const SizedBox(height: 32),
                      _buildActionBar(isDark),
                      const SizedBox(height: 24),
                      _buildCommentsHeader(isDark),
                      const SizedBox(height: 10),
                      _buildCompactReplies(isDark),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      _buildReplyBar(isDark),
    ]);
  }

  Widget _buildMarketHeroImage(Post p, bool isDark, {bool forceFitHeight = false}) {
    final urls = _resolvedImageUrls(p);
    if (urls.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: forceFitHeight ? double.infinity : 400,
          color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
          child: PageView.builder(
            itemCount: urls.length,
            onPageChanged: (index) => setState(() => _marketImageIndex = index),
            itemBuilder: (_, index) => GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(imageUrls: urls, initialIndex: index),
                ),
              ),
              child: CachedNetworkImage(
                cacheManager: PostImageCache.manager,
                imageUrl: urls[index],
                width: double.infinity,
                fit: forceFitHeight ? BoxFit.contain : BoxFit.cover,
                placeholder: (_, __) => Container(color: isDark ? Colors.white10 : Colors.grey[200]),
                errorWidget: (_, __, ___) => Container(
                  color: isDark ? Colors.white10 : Colors.grey[200],
                  child: const Icon(Icons.broken_image, size: 40, color: Colors.grey),
                ),
              ),
            ),
          ),
        ),
        if (urls.length > 1)
          Positioned(
            bottom: 40,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '${_marketImageIndex + 1}/${urls.length}',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
    );
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
        CachedAvatar(
          radius: 24,
          imageUrl: p.author?.avatar.isNotEmpty == true
              ? ApiConstants.fullUrl(p.author!.avatar)
              : null,
          fallbackText: p.author?.nickname,
        ),
        const SizedBox(width: 14),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              children: [
                Flexible(
                  child: Text(p.author?.nickname ?? '匿名',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black87)),
                ),
                if (p.author != null) ...[
                  const SizedBox(width: 6),
                  _buildLevelBadge(p.author!, isDark),
                ],
              ],
            ),
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
              const SizedBox(width: 8),
              Icon(Icons.visibility_outlined, size: 13,
                  color: isDark ? Colors.white30 : Colors.grey[400]),
              const SizedBox(width: 3),
              Text('${p.viewCount}',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white30 : Colors.grey[400])),
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
        icon: _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF222731) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.alternate_email_rounded,
                size: 20, color: Theme.of(context).primaryColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('联系方式',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white54 : Colors.grey[500])),
                const SizedBox(height: 3),
                Text(contact,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: isDark ? Colors.white : Colors.black87)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: isDark
                  ? []
                  : [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 4,
                          offset: const Offset(0, 2))
                    ],
            ),
            child: Row(
              children: [
                Icon(Icons.copy_rounded,
                    size: 14, color: isDark ? Colors.white70 : Colors.black54),
                const SizedBox(width: 4),
                Text('一键复制',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : Colors.black54)),
              ],
            ),
          ),
        ],
      ),
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
    final threads = _buildThreads();
    return Column(
      children: threads.take(4).map((t) => _buildReplyThread(t, isDark, compact: true, depth: 0)).toList(),
    );
  }

  Widget _buildFullReplies(bool isDark) {
    if (_replies.isEmpty) return _buildNoComments(isDark);
    final threads = _buildThreads();
    return Column(
      children: threads.map((t) => _buildReplyThread(t, isDark, compact: false, depth: 0)).toList(),
    );
  }

  /// 将回复构建为楼中楼结构：顶级评论 + 所有子回复扁平展示
  List<_ReplyThread> _buildThreads() {
    final childMap = <int, List<Reply>>{};
    for (final r in _replies) {
      if (r.parentReplyId != null) {
        childMap.putIfAbsent(r.parentReplyId!, () => []).add(r);
      }
    }

    // 扁平收集所有子回复（不管嵌套多深）
    List<Reply> flattenChildren(int parentId) {
      final directChildren = childMap[parentId] ?? [];
      final result = <Reply>[];
      for (final child in directChildren) {
        result.add(child);
        // 不再递归，把所有层级的回复都收集到同一层级
      }
      return result;
    }

    _ReplyThread buildNode(Reply reply) {
      // 所有子回复扁平化
      final flatChildren = flattenChildren(reply.id);
      return _ReplyThread(parent: reply, children: flatChildren);
    }

    final topLevel = _replies.where((r) => r.parentReplyId == null).toList();
    return topLevel.map(buildNode).toList();
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

  Widget _buildReplyThread(_ReplyThread thread, bool isDark, {bool compact = false, int depth = 0}) {
    // 获取该顶级评论的所有子回复（扁平化）
    final childMap = <int, List<Reply>>{};
    for (final r in _replies) {
      if (r.parentReplyId != null) {
        childMap.putIfAbsent(r.parentReplyId!, () => []).add(r);
      }
    }
    final allChildren = childMap[thread.parent.id] ?? [];
    final isExpanded = _expandedThreads.contains(thread.parent.id);
    final visibleChildren = !isExpanded
        ? allChildren.take(2).toList()
        : allChildren;
    final hasMore = !isExpanded && allChildren.length > 2;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主评论
          _buildMainReply(thread.parent, isDark),
          // 子回复区域（扁平化展示）
          if (visibleChildren.isNotEmpty)
            Container(
              margin: EdgeInsets.only(left: 42.0, top: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.grey.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...visibleChildren.map(
                    (child) => _buildChildReply(child, isDark, depth: 0),
                  ),
                  if (hasMore)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _expandedThreads.add(thread.parent.id);
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '共${allChildren.length}条回复，点击查看',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 子回复线程：显示扁平化后的所有子回复（不再递归嵌套）
  Widget _buildChildReplyThread(_ReplyThread thread, bool isDark, {bool compact = false, int depth = 0}) {
    // 扁平化后：从 childMap 中获取该顶级评论的所有子回复
    final childMap = <int, List<Reply>>{};
    for (final r in _replies) {
      if (r.parentReplyId != null) {
        childMap.putIfAbsent(r.parentReplyId!, () => []).add(r);
      }
    }
    final directChildren = childMap[thread.parent.id] ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: directChildren.map(
        (child) => _buildChildReply(child, isDark, depth: 0),
      ).toList(),
    );
  }

  /// 主评论（顶级）
  Widget _buildMainReply(Reply r, bool isDark) {
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == r.authorId;
    return _buildHighlightWrapper(
      r,
      isDark,
      GestureDetector(
        onTap: () => _openReplyComposer(parentReplyId: r.id, replyToName: r.author?.nickname, replyToUserId: r.authorId),
        onLongPress: () => _showReplyActionSheet(r, isOwn, isDark),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CachedAvatar(
            radius: 16,
            imageUrl: r.author?.avatar.isNotEmpty == true
                ? ApiConstants.fullUrl(r.author!.avatar)
                : null,
            fallbackText: r.author?.nickname,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(r.author?.nickname ?? '匿名',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.80)
                              : Colors.black87)),
                  if (r.author != null) ...[
                    const SizedBox(width: 4),
                    _buildLevelBadge(r.author!, isDark),
                  ],
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
                const SizedBox(height: 4),
                SelectionContainer.disabled(
                  child: Text(r.content,
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: isDark ? Colors.white70 : Colors.grey[800])),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.reply, size: 14,
                        color: isDark ? Colors.white30 : Colors.grey[400]),
                    const SizedBox(width: 4),
                    Text('回复', style: TextStyle(fontSize: 11,
                        color: isDark ? Colors.white30 : Colors.grey[400])),
                  ],
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// 子回复（楼中楼）
  Widget _buildChildReply(Reply r, bool isDark, {int depth = 0}) {
    // 从 content 中解析 @username
    final contentWidget = _buildChildContent(r, isDark);
    // 回复按钮指向顶级评论（楼中楼的根），避免多层嵌套
    final threadParentId = _findTopLevelParentId(r);
    final currentUser = context.read<AuthProvider>().user;
    final isOwn = currentUser?.id == r.authorId;
    return _buildHighlightWrapper(
      r,
      isDark,
      GestureDetector(
        onTap: () => _openReplyComposer(parentReplyId: threadParentId, replyToName: r.author?.nickname, replyToUserId: r.authorId),
        onLongPress: () => _showReplyActionSheet(r, isOwn, isDark),
        child: Padding(
          padding: EdgeInsets.only(bottom: 8, left: depth * 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CachedAvatar(
                radius: 10,
                imageUrl: r.author?.avatar.isNotEmpty == true
                    ? ApiConstants.fullUrl(r.author!.avatar)
                    : null,
                fallbackText: r.author?.nickname,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(r.author?.nickname ?? '匿名',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.70)
                                  : Colors.black87)),
                      if (r.author != null) ...[
                        const SizedBox(width: 4),
                        _buildLevelBadgeSmall(r.author!, isDark),
                      ],
                      const SizedBox(width: 8),
                      Text(_formatTime(r.createdAt),
                          style: TextStyle(
                              fontSize: 10,
                              color: isDark ? Colors.white24 : Colors.grey[400])),
                      const Spacer(),
                      Text('回复', style: TextStyle(fontSize: 10,
                          color: isDark ? Colors.white24 : Colors.grey[400])),
                    ]),
                    const SizedBox(height: 2),
                    contentWidget,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHighlightWrapper(Reply r, bool isDark, Widget child) {
    final key = _replyKeys.putIfAbsent(r.id, () => GlobalKey());
    final isTarget = widget.targetReplyId == r.id;
    return KeyedSubtree(
      key: key,
      child: isTarget
          ? TweenAnimationBuilder<Color?>(
              tween: ColorTween(
                begin: Theme.of(context).primaryColor.withValues(alpha: 0.3),
                end: Colors.transparent,
              ),
              duration: const Duration(milliseconds: 1500),
              builder: (context, color, child) {
                return Container(
                  color: color,
                  child: child,
                );
              },
              child: child,
            )
          : child,
    );
  }

  /// 解析子回复内容中的 @用户名 并高亮
  Widget _buildChildContent(Reply r, bool isDark) {
    final content = r.content;
    final atRegex = RegExp(r'^@(\S+)\s');
    final match = atRegex.firstMatch(content);
    
    Widget textWidget;
    if (match != null) {
      final atName = match.group(1)!;
      final rest = content.substring(match.end);
      textWidget = Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '@$atName ',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: Theme.of(context).primaryColor,
              fontWeight: FontWeight.w500,
            ),
          ),
          TextSpan(
            text: rest,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark ? Colors.white60 : Colors.grey[700],
            ),
          ),
        ]),
      );
    } else {
      textWidget = Text(content,
          style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark ? Colors.white60 : Colors.grey[700]));
    }
    // 禁用文字选择，让行级长按直接弹出操作菜单
    return SelectionContainer.disabled(child: textWidget);
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
                  hintText: _replyToName != null ? '回复 @$_replyToName...' : '写下你的想法...',
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
              onTap: _isSending ? null : _sendReply,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: _isSending
                      ? const LinearGradient(
                          colors: [Color(0xFF9CA3AF), Color(0xFF9CA3AF)])
                      : const LinearGradient(
                          colors: [Color(0xFF667EEA), Color(0xFF764BA2)]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: _isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : const Icon(Icons.send_rounded,
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

  /// 查找回复的顶级评论id（楼中楼的根）
  int _findTopLevelParentId(Reply r) {
    // 查找这条回复的顶级父评论
    final parentMap = <int, int>{}; // replyId -> parentReplyId
    for (final reply in _replies) {
      if (reply.parentReplyId != null) {
        parentMap[reply.id] = reply.parentReplyId!;
      }
    }
    // 循环向上找到顶级评论
    int currentId = r.id;
    while (parentMap.containsKey(currentId)) {
      currentId = parentMap[currentId]!;
    }
    // currentId 现在是顶级评论的id
    return currentId;
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

  Widget _buildLevelBadge(User user, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Color(user.levelColorValue).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        user.levelLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Color(user.levelColorValue),
        ),
      ),
    );
  }

  Widget _buildLevelBadgeSmall(User user, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Color(user.levelColorValue).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        user.levelLabel,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          color: Color(user.levelColorValue),
        ),
      ),
    );
  }

  void _openReplyComposer({int? parentReplyId, String? replyToName, int? replyToUserId}) {
    setState(() {
      _isReplyComposerOpen = true;
      _parentReplyId = parentReplyId;
      _replyToName = replyToName;
      _replyToUserId = replyToUserId;
      if (replyToName != null && replyToName.isNotEmpty) {
        _replyController.text = '@$replyToName ';
        _replyController.selection = TextSelection.fromPosition(
          TextPosition(offset: _replyController.text.length),
        );
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _replyFocus.requestFocus();
      }
    });
  }

  void _showReplyActionSheet(Reply r, bool isOwn, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E32) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(Icons.copy, color: isDark ? Colors.white70 : Colors.black87),
              title: Text('复制', style: TextStyle(color: isDark ? Colors.white70 : Colors.black87)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: r.content));
                Navigator.pop(ctx);
                AppFeedback.showSnackBar(context, '已复制');
              },
            ),
            if (isOwn)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('删除', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteReply(r);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteReply(Reply r) async {
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '删除回复',
      message: '确定要删除这条回复吗？',
    );
    if (!confirmed) return;
    try {
      await _dio.delete('/replies/${r.id}');
      if (mounted) {
        AppFeedback.showSnackBar(context, '已删除');
        if (_post != null && _post!.replyCount > 0) {
          setState(() {
            _post = _post!.copyWith(replyCount: _post!.replyCount - 1);
          });
          context.read<PostProvider>().updatePostInCache(_post!);
        }
        _loadReplies();
      }
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '删除失败');
      if (mounted) {
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }

  Future<void> _loadReplies() async {
    try {
      final repliesResponse = await _dio.get('/posts/${widget.postId}/replies');
      setState(() {
        _replies = (repliesResponse.data as List)
            .map((e) => Reply.fromJson(e))
            .toList();
      });
    } on DioException catch (e) {
      final msg = AppFeedback.dioErrorMessage(e, fallback: '加载回复失败');
      if (mounted) {
        AppFeedback.showSnackBar(context, msg, isError: true);
      }
    }
  }
}

/// 楼中楼数据结构（扁平化子回复）
class _ReplyThread {
  final Reply parent;
  final List<Reply> children; // 直接子回复列表，不再递归
  _ReplyThread({required this.parent, required this.children});
}
